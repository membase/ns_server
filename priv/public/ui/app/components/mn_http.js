(function () {
  "use strict";

  angular
    .module('mnHttp', ["mnPendingQueryKeeper"])
    .factory('mnHttp', mnHttpFactory);

  function mnHttpFactory($http, $q, $timeout, $httpParamSerializerJQLike, mnPendingQueryKeeper) {

    createShortMethods('get', 'delete', 'head', 'jsonp');
    createShortMethodsWithData('post', 'put');

    return mnHttp;

    function mnHttp(config) {
      var pendingQuery = {
        config: _.clone(config)
      };
      var mnHttpConfig = config.mnHttp || {};
      delete config.mnHttp;
      if (config.method.toLowerCase() === "post" && mnHttpConfig.cancelPrevious) {
        var queryInFly = mnPendingQueryKeeper.getQueryInFly(config);
        queryInFly && queryInFly.canceler();
      }
      var canceler = $q.defer();
      var timeoutID;
      var timeout = config.timeout;
      var isCleared;

      function clear() {
        if (isCleared) {
          return;
        }
        isCleared = true;
        timeoutID && $timeout.cancel(timeoutID);
        mnPendingQueryKeeper.removeQueryInFly(pendingQuery);
      }

      function cancel(reason) {
        return function () {
          canceler.resolve(reason);
          clear();
        };
      }

      switch (config.method.toLowerCase()) {
        case 'post':
        case 'put':
          config.headers = config.headers || {};
          if (!mnHttpConfig.isNotForm) {
            config.headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8';
            if (!angular.isString(config.data)) {
              config.data = $httpParamSerializerJQLike(config.data);
            }
          }
        break;
      }

      config.timeout = canceler.promise;
      var http = $http(config);
      http.then(clear, clear);

      if (timeout) {
        timeoutID = $timeout(cancel("timeout"), timeout);
      }

      pendingQuery.canceler = cancel("cancelled");
      pendingQuery.httpPromise = http;
      mnPendingQueryKeeper.push(pendingQuery);

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
  }

})();
