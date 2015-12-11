(function () {
  "use strict";

  angular
    .module('mnHttp', ["mnPendingQueryKeeper"])
    .factory('mnHttpInterceptor', mnHttpFactory)
    .config(function ($httpProvider) {
      $httpProvider.interceptors.push('mnHttpInterceptor');
    });

  function mnHttpFactory(mnPendingQueryKeeper, $q, $httpParamSerializerJQLike, $timeout) {
    var myHttpInterceptor = {
      request: request,
      response: response
    };

    return myHttpInterceptor;

    function request(config) {
      if (config.url.indexOf(".html") !== -1 || config.doNotIntercept) {
        return config;
      } else {
        return intercept(config);
      }
    }
    function intercept(config) {
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
      config.clear = clear;

      pendingQuery.canceler = cancel("cancelled");
      pendingQuery.group = mnHttpConfig.group;
      mnPendingQueryKeeper.push(pendingQuery);

      if (timeout) {
        timeoutID = $timeout(cancel("timeout"), timeout);
      }

      return config;
    }

    function response(response) {
      if (response.config.clear && angular.isFunction(response.config.clear)) {
        response.config.clear();
        delete response.config.clear;
      }
      return response;
    }
  }

})();
