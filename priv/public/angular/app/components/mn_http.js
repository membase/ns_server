angular.module('mnHttp', [
]).factory('mnHttp',
  function ($http, $q, $timeout, $httpParamSerializerJQLike) {
    var pendingQueryCancelers = {};
    function mnHttp(config) {
      var canceler = $q.defer();
      var timeout = config.timeout;
      config.timeout = canceler.promise;
      if (config.cancelPrevious) {
        var id = config.method + ":" + config.url;
      } else {
        var id = _.uniqueId('http');
      }
      var timeoutID;
      var isCleared;
      function clear() {
        if (isCleared) {
          return;
        }
        isCleared = true;
        timeoutID && $timeout.cancel(timeoutID);
        delete pendingQueryCancelers[id];
      }
      if (config.cancelPrevious && pendingQueryCancelers[id]) {
        pendingQueryCancelers[id]();
      }
      pendingQueryCancelers[id] = function () {
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
        case 'put':
          if (!config.notForm) {
            config.headers = _.extend({
              'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'
            }, config.headers);
          } else {
            delete config.notForm;
          }
          if (!angular.isString(config.data)) {
            config.data = $httpParamSerializerJQLike(config.data);
          }
        break;
      }
      delete config.cancelPrevious;
      var http = $http(config);
      http.then(clear, clear);
      return http;
    }
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
