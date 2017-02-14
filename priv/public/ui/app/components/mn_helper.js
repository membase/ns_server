(function () {
  "use strict";

  angular
    .module('mnHelper', [
      'ui.router',
      'mnTasksDetails',
      'mnAlertsService',
      'mnBucketsService'
    ])
    .provider('mnHelper', mnHelperProvider);

  function mnHelperProvider() {

    return {
      $get: mnHelperFactory,
      setDefaultBucketName: setDefaultBucketName
    };

    function setDefaultBucketName(bucketParamName, stateRedirect, memcached) {
      return function ($q, $state, mnBucketsService, $transition$) {
        var deferred = $q.defer();
        var params = $transition$.params();
        if (params[bucketParamName] === null) {
          mnBucketsService.getBucketsByType(true).then(function (buckets) {
            var defaultBucket = memcached ? buckets.byType.defaultName : buckets.byType.membase.defaultName || buckets.byType.ephemeral.defaultName;
            if (!defaultBucket) {
              deferred.resolve();
            } else {
              deferred.reject();
              params[bucketParamName] = defaultBucket;
              $state.go(stateRedirect, _.clone(params));
            }
          });
        } else {
          deferred.resolve();
        }

        return deferred.promise;
      };
    }
    function mnHelperFactory($window, $state, $location, $timeout, $q, mnTasksDetails, mnAlertsService, $http, mnPendingQueryKeeper) {
      var mnHelper = {
        wrapInFunction: wrapInFunction,
        calculateMaxMemorySize: calculateMaxMemorySize,
        initializeDetailsHashObserver: initializeDetailsHashObserver,
        checkboxesToList: checkboxesToList,
        reloadApp: reloadApp,
        reloadState: reloadState,
        listToCheckboxes: listToCheckboxes
      };

      return mnHelper;

      function wrapInFunction(value) {
        return function () {
          return value;
        };
      }
      function calculateMaxMemorySize(totalRAMMegs) {
        return Math.floor(Math.max(totalRAMMegs * 0.8, totalRAMMegs - 1024));
      }
      function initializeDetailsHashObserver($scope, hashKey, stateName) {
        function getHashValue() {
          return _.clone($state.params[hashKey]) || [];
        }
        $scope.isDetailsOpened = function (hashValue) {
          return _.contains(getHashValue(), String(hashValue));
        };
        $scope.toggleDetails = function (hashValue) {
          var currentlyOpened = getHashValue();
          var stateParams = {};
          if ($scope.isDetailsOpened(hashValue)) {
            stateParams[hashKey] = _.difference(currentlyOpened, [String(hashValue)]);
            $state.go(stateName, stateParams);
          } else {
            currentlyOpened.push(String(hashValue));
            stateParams[hashKey] = currentlyOpened;
            $state.go(stateName, stateParams);
          }
        };
      }
      function checkboxesToList(object) {
        return _.chain(object).pick(angular.identity).keys().value();
      }
      function listToCheckboxes(list) {
        return _.zipObject(list, _.fill(new Array(list.length), true, 0, list.length));
      }
      function reloadApp() {
        $window.location.reload();
      }
      function reloadState(state) {
        mnPendingQueryKeeper.cancelAllQueries();
        return $state.reload(state);
      }
    }
  }
})();
