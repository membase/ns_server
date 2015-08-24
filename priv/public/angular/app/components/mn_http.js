angular.module('mnHttp', [
]).factory('mnHttp',
  function ($http, $q, $timeout, $httpParamSerializerJQLike) {
    //We need to associate the http with specific scope.
    //This helps prevent pending asynchronous operations from causing side effects after the scope in which they were initiated is destroyed.
    //The simplest way to keep queries organized by the groups. Currenly there are three kind of groups or layres of http queries
    //httpGroup:
    //globals - like /pools/default or /pools/default/tasks
    //defaults - tab or section specific queries
    //modals - queries in modal window (we don't care about this one because modal window could be blocked during async in the future)
    var pendingQueryCancelers = {
      globals: {},
      defaults: {}
    };
    function mnHttp(config) {
      var httpGroup = config.httpGroup || "defaults";
      var canceler = $q.defer();
      var timeout = config.timeout;
      config.timeout = canceler.promise;
      var id = _.uniqueId('http');
      var timeoutID;
      function clear() {
        timeoutID && $timeout.cancel(timeoutID);
        delete pendingQueryCancelers[httpGroup][id];
      }
      pendingQueryCancelers[httpGroup][id] = function () {
        canceler.resolve("cancelled");
        clear();
      };
      if (timeout) {
        timeoutID = $timeout(function () {
          canceler.resolve("timeout");
          clear();
        }, timeout);
      }
      switch (config.method.toLowerCase()) {
        case 'post':
          if (!config.notForm) {
            config.headers = _.extend({
              'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'
            }, config.headers);
          } else {
            delete config.notForm;
          }

          config.data = $httpParamSerializerJQLike(config.data);
        break;
      }
      delete config.httpGroup;
      var http = $http(config);
      http.then(clear, clear);
      return http;
    }
    mnHttp.cancelDefaults = function () {
      _.forEach(pendingQueryCancelers.defaults, function (canceler) {
        canceler();
      });
    };
    mnHttp.cancelAll = function () {
      mnHttp.cancelDefaults();
      _.forEach(pendingQueryCancelers.globals, function (canceler) {
        canceler();
      });
    };
    function createShortMethods(names) {
      _.each(arguments, function (name) {
        mnHttp[name] = function (url, config) {
          return mnHttp(_.extend(config || {}, {
            method: name,
            url: url
          }));
        };
      });
    }
    function createShortMethodsWithData(name) {
      _.each(arguments, function (name) {
        mnHttp[name] = function (url, data, config) {
          return mnHttp(_.extend(config || {}, {
            method: name,
            url: url,
            data: data
          }));
        };
      });
    }

    createShortMethods('get', 'delete', 'head', 'jsonp');
    createShortMethodsWithData('post', 'put');
    return mnHttp;
  });
