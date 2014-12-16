angular.module('mnHelper').factory('mnHelper',
  function ($window, $state, $stateParams, $location, $timeout) {
    var mnHelper = {};

    mnHelper.handleSpinner = function ($scope, promise, name, isInfinitForSuccess) {
      if (!name) {
        name = 'viewLoading';
      }
      function spinnerCtrl(isLoaded) {
        $scope[name] = isLoaded;
      }
      function hideSpinner() {
        spinnerCtrl(false);
        return promise;
      }
      spinnerCtrl(true);
      if (promise.success) {
        var rv = promise.error(hideSpinner);
        return isInfinitForSuccess ? rv : rv.success(hideSpinner);
      } else {
        return promise.then(isInfinitForSuccess ? null : hideSpinner, hideSpinner);
      }
    };

    mnHelper.setupLongPolling = function (config) {
      var cycleId;
      (function cycle() {
        config.methodToCall.apply(null, config.methodParams).then(function (rv) {
          cycleId = $timeout(cycle, rv.recommendedRefreshPeriod || 20000);
          return rv;
        }).then(config.onUpdate);
      })();

      config.scope.$on('$destroy', function () {
        $timeout.cancel(cycleId);
      });
    };

    mnHelper.initializeDetailsHashObserver = function ($scope, hashKey) {
      function getOpenedServers() {
        var value = $location.search()[hashKey];
        return value ? _.isArray(value) ? value : [value] : [];
      }
      $scope.isDetailsOpened = function (hashValue) {
        return _.contains(getOpenedServers(), hashValue);
      };
      $scope.toggleDetails = function (hashValue) {
        var currentlyOpened = getOpenedServers();
        if ($scope.isDetailsOpened(hashValue)) {
          $location.search(hashKey, _.difference(currentlyOpened, [hashValue]));
        } else {
          currentlyOpened.push(hashValue);
          $location.search(hashKey, currentlyOpened);
        }
      };
    };

    mnHelper.checkboxesToList = function (object) {
      return _(object).pick(angular.identity).keys().value();
    };

    mnHelper.reloadApp = function () {
      $window.location.reload();
    };

    mnHelper.reloadState = function () {
      $state.transitionTo($state.current, $stateParams, {reload: true, inherit: true, notify: true});
    };

    mnHelper.rejectReasonToScopeApplyer = function ($scope, name, promise) {
      if (!promise) {
        promise = name;
        name = 'errors';
      }
      function errorsCtrl(errors) {
        $scope[name] = errors;
      }
      function success() {
        errorsCtrl(false);
        return promise;
      }
      if (promise.success) {
        return promise.success(success).error(errorsCtrl);
      } else {
        return promise.then(success, function (resp) {
          errorsCtrl(resp.data);
          return promise;
        });
      }
    };

    return mnHelper;
  });
