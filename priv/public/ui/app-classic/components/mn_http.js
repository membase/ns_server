(function () {
  "use strict";

  angular
    .module('mnHttp', ["mnPendingQueryKeeper"])
    .factory('mnHttpInterceptor', mnHttpFactory)
    .config(function ($httpProvider) {
      $httpProvider.interceptors.push('mnHttpInterceptor');
    });

  function mnHttpFactory(mnPendingQueryKeeper, $q, $httpParamSerializerJQLike, $timeout, $exceptionHandler) {
    var myHttpInterceptor = {
      request: request,
      response: response,
      responseError: responseError
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
              config.data = jQueryLikeParamSerializer(config.data);
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

    function serializeValue(v) {
      if (angular.isObject(v)) {
        return angular.isDate(v) ? v.toISOString() : angular.toJson(v);
      }
      return v;
    }
    //function is borrowed from the Angular source code because we want to
    //use $httpParamSerializerJQLik but with properly encoded params via
    //encodeURIComponent since it uses correct application/x-www-form-urlencoded
    //encoding algorithm, in accordance with
    //https://www.w3.org/TR/html5/forms.html#url-encoded-form-data
    function jQueryLikeParamSerializer(params) {
      if (!params) {
        return '';
      }
      var parts = [];
      serialize(params, '', true);
      return parts.join('&');

      function serialize(toSerialize, prefix, topLevel) {
        if (toSerialize === null || angular.isUndefined(toSerialize)) {
          return;
        }
        if (angular.isArray(toSerialize)) {
          angular.forEach(toSerialize, function (value, index) {
            serialize(value, prefix + '[' + (angular.isObject(value) ? index : '') + ']');
          });
        } else if (angular.isObject(toSerialize) && !angular.isDate(toSerialize)) {
          angular.forEach(toSerialize, function (value, key) {
            serialize(value, prefix +
                (topLevel ? '' : '[') +
                key +
                (topLevel ? '' : ']'));
          });
        } else {
          parts.push(encodeURIComponent(prefix) + '=' + encodeURIComponent(serializeValue(toSerialize)));
        }
      }
    }

    function clearOnResponse(response) {
      if (response.config.clear && angular.isFunction(response.config.clear)) {
        response.config.clear();
        delete response.config.clear;
      }
    }

    function response(response) {
      clearOnResponse(response);
      return response;
    }
    function responseError(response) {
      if (response instanceof Error) {
        $exceptionHandler(response);
      }
      clearOnResponse(response);
      return $q.reject(response);
    }
  }

})();
