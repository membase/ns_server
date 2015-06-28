angular.module('mnHelper', [
  'ui.router',
  'mnTasksDetails',
  'mnAlertsService',
  'mnHttp'
]).factory('mnHelper',
  function ($window, $state, $stateParams, $location, $timeout, $q, mnTasksDetails, mnAlertsService, mnHttp) {
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
        prepareErrors: function (cb) {
          promise.then(null, cb);
          return this
        },
        catchErrors: function (name) {
          name && setErrorsName(name);
          promise.then(removeErrors, function (resp) {
            errorsCtrl(extractErrors(resp));
          });
          return this;
        },
        catchGlobalErrors: function (errorMessage, timeout) {
          promise.then(null, function (resp) {
            mnAlertsService.formatAndSetAlerts(errorMessage || resp.data, 'danger', timeout);
          });
          return this;
        },
        showGlobalSuccess: function (successMessage, timeout) {
          promise.then(function (resp) {
            mnAlertsService.formatAndSetAlerts(successMessage || resp.data, 'success', timeout);
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

    function createPromiseHelperShortcuts(name) {
      mnHelper[name] = function (scope, promise, scopeName) {
        return mnHelper.promiseHelper(scope, promise)[name](scopeName).getPromise();
      };
    }
    angular.forEach(['showSpinner', 'showErrorsSensitiveSpinner', 'catchErrors'], createPromiseHelperShortcuts);

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
