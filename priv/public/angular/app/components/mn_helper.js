angular.module('mnHelper').factory('mnHelper',
  function ($window, $state, $stateParams, $location, $timeout, $q, mnTasksDetails, mnAlertsService) {
    var mnHelper = {};


    mnHelper.promiseHelper = function (scope, promise, modalInstance) {
      var spinnerName = 'viewLoading';
      var errorsName = 'errors';
      function spinnerCtrl(isLoaded) {
        scope[spinnerName] = isLoaded;
      }
      function errorsCtrl(errors) {
        scope[errorsName] = errors;
      }
      function hideSpinner() {
        spinnerCtrl(false);
      }
      function removeErrors() {
        errorsCtrl(false);
      }
      function setSpinnerName(name) {
        spinnerName = name;
      }
      function setErrorsName(name) {
        errorsName = name;
      }
      function closeModal() {
        modalInstance.close();
      }
      function extractErrors(resp) {
        var errors = resp.data && resp.data.errors || resp.data;
        return _.isEmpty(errors) ? false : errors;
      }
      return {
        getPromise: function () {
          return promise;
        },
        reloadState: function () {
          promise.then(function () {
            mnHelper.reloadState();
          });
          return this;
        },
        closeFinally: function () {
          promise['finally'](closeModal);
          return this;
        },
        closeOnSuccess: function () {
          promise.then(closeModal);
          return this;
        },
        showErrorsSensitiveSpinner: function (name) {
          name && setSpinnerName(name);
          spinnerCtrl(true);
          promise.then(null, hideSpinner);
          return this;
        },
        catchErrorsFromSuccess: function (name) {
          name && setErrorsName(name);
          promise.then(function (resp) {
            errorsCtrl(extractErrors(resp));
          });
          return this;
        },
        showSpinner: function (name) {
          name && setSpinnerName(name);
          spinnerCtrl(true);
          promise.then(hideSpinner, hideSpinner);
          return this;
        },
        catchErrors: function (name) {
          name && setErrorsName(name);
          promise.then(removeErrors, function (resp) {
            errorsCtrl(extractErrors(resp));
          });
          return this;
        },
        catchGlobalErrors: function (errorMessage) {
          promise.then(null, function (resp) {
            mnAlertsService.formatAndSetAlerts(resp.data || errorMessage, 'danger');
          });
          return this;
        }
      };
    };

    mnHelper.handleModalAction = function ($scope, promise, $modalInstance) {
      return mnHelper
        .promiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .closeFinally()
        .reloadState();
    };

    function createPromiseHelperShortcuts(name) {
      mnHelper[name] = function (scope, promise, scopeName) {
        return mnHelper.promiseHelper(scope, promise)[name](scopeName).getPromise();
      };
    }
    angular.forEach(['showSpinner', 'showErrorsSensitiveSpinner', 'catchErrors'], createPromiseHelperShortcuts);

    mnHelper.setupLongPolling = function (config) {
      var cycleId;
      function cycle() {
        $q.all([
          config.methodToCall(),
          mnTasksDetails.get()
        ]).then(function (result) {
          var tasks = result[1];
          var rv = result[0];
          var recommendedRefreshPeriod = (_(tasks.tasks).pluck('recommendedRefreshPeriod').compact().min().value() * 1000) >> 0 || 10000;
          cycleId = $timeout(cycle, recommendedRefreshPeriod || 20000);
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

    return mnHelper;
  });
