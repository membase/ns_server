(function () {
  "use strict";

  angular
    .module('mnHttp', [])
    .factory('mnHttp', mnHttpFactory);

  function mnHttpFactory($http, $q, $timeout, $httpParamSerializerJQLike, $state) {

    var pendingQueryKeeper = [];

    mnHttp.attachPendingQueriesToScope = attachPendingQueriesToScope;
    mnHttp.markAsIndependetOfScope = markAsIndependetOfScope;

    createShortMethods('get', 'delete', 'head', 'jsonp');
    createShortMethodsWithData('post', 'put');

    return mnHttp;

    function attachPendingQueriesToScope($scope) {
      var queries = getQueriesOfRecentPromise();
      _.forEach(queries, function (query) {
        query.isAttachedToScope = true;
        $scope.$on("$destroy", query.canceler);
      });
    }

    function markAsIndependetOfScope() {
      var queries = getQueriesOfRecentPromise();
      _.forEach(queries, function (query) {
        query.doesNotBelongToScope = true;
      });
    }

    function getQueriesOfRecentPromise() {
      return _.takeRightWhile(pendingQueryKeeper, function (query) {
        return !query.isAttachedToScope && !query.doesNotBelongToScope;
      });
    }

    function removeQueryInFly(findMe) {
      _.remove(pendingQueryKeeper, function (pendingQuery) {
        return pendingQuery === findMe;
      });
    }

    function getQueryInFly(config) {
      return _.find(pendingQueryKeeper, function (inFly) {
        return inFly.config.method === config.method &&
               inFly.config.url === config.url;
      });
    }

    function mnHttp(config) {
      var pendingQuery = {
        config: _.clone(config)
      };
      if (config.method.toLowerCase() === "post" && config.cancelPrevious) {
        var queryInFly = getQueryInFly(config);
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
        removeQueryInFly(pendingQuery);
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
          if (config.isNotForm) {
            config.headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8';
            if (!angular.isString(config.data)) {
              config.data = $httpParamSerializerJQLike(config.data);
            }
          } else {
            delete config.isNotForm;
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
      pendingQueryKeeper.push(pendingQuery);

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
