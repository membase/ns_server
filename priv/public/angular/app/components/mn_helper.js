angular.module('mnHelper', [
  'ui.router',
  'mnTasksDetails',
  'mnAlertsService',
  'mnHttp'
]).factory('mnHelper',
  function ($window, $state, $stateParams, $location, $timeout, $q, mnTasksDetails, mnAlertsService, mnHttp) {
    var mnHelper = {};

    mnHelper.cancelCurrentStateHttpOnScopeDestroy = function ($scope) {
      $scope.$on("$destroy", function () {
        mnHttp.cancelDefaults();
      });
    };
    mnHelper.cancelAllHttpOnScopeDestroy = function ($scope) {
      $scope.$on("$destroy", function () {
        mnHttp.cancelAll();
      });
    };

    mnHelper.setupLongPolling = function (config) {
      var cycleId;
      var previousResult;
      function cycle() {
        var queries = [config.methodToCall(previousResult)];
        if (!config.extractRefreshPeriod) {
          queries.push(mnTasksDetails.get());
        }
        $q.all(queries).then(function (result) {
          var rv = result[0];
          var tasks = result[1];
          previousResult = rv;
          var recommendedRefreshPeriod = 20000;
          if (tasks) {
            recommendedRefreshPeriod = (_.chain(tasks.tasks).pluck('recommendedRefreshPeriod').compact().min().value() * 1000) >> 0 || 10000;
          } else {
            if (config.extractRefreshPeriod) {
              recommendedRefreshPeriod = config.extractRefreshPeriod(rv);
            }
          }
          cycleId = $timeout(cycle, recommendedRefreshPeriod);
          return rv;
        }).then(config.onUpdate);
      }
      cycle();

      config.scope.$on('$destroy', function () {
        $timeout.cancel(cycleId);
      });

      return {
        reload: function () {
          $timeout.cancel(cycleId);
          cycle();
        }
      };
    };

    mnHelper.wrapInFunction = function (value) {
      return function () {
        return value;
      };
    };

    mnHelper.initializeDetailsHashObserver = function ($scope, hashKey, stateName) {
      function getHashValue() {
        return $stateParams[hashKey] || [];
      }
      $scope.isDetailsOpened = function (hashValue) {
        return _.contains(getHashValue(), String(hashValue));
      };
      $scope.toggleDetails = function (hashValue) {
        var currentlyOpened = getHashValue();
        var stateParams = {};
        if ($scope.isDetailsOpened(hashValue)) {
          stateParams[hashKey] = _.difference(currentlyOpened, [String(hashValue)]);
          $state.go(stateName, stateParams, {notify: false});
        } else {
          currentlyOpened.push(String(hashValue));
          stateParams[hashKey] = currentlyOpened;
          $state.go(stateName, stateParams, {notify: false});
        }
      };
    };

    mnHelper.checkboxesToList = function (object) {
      return _.chain(object).pick(angular.identity).keys().value();
    };

    mnHelper.reloadApp = function () {
      $window.location.reload();
    };

    mnHelper.reloadState = function () {
      $state.transitionTo($state.current, $stateParams, {reload: true, inherit: true, notify: true});
    };

    return mnHelper;
  });
