angular.module('mnPromiseHelper', [
  'mnAlertsService',
  'mnHelper'
]).factory('mnPromiseHelper',
  function (mnAlertsService, mnHelper, mnPoll, $timeout) {

    mnPromiseHelper.handleModalAction = function ($scope, promise, $modalInstance) {
      return mnPromiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .closeFinally()
        .reloadState();
    };

    function mnPromiseHelper(scope, promise, modalInstance) {
      var spinnerName = 'viewLoading';
      var errorsNameOrCallback = 'errors';
      function spinnerCtrl(isLoaded) {
        scope[spinnerName] = isLoaded;
      }
      function errorsCtrl(errors) {
        if (angular.isFunction(errorsNameOrCallback)) {
          errorsNameOrCallback(errors);
        } else {
          scope[errorsNameOrCallback] = errors;
        }
      }
      function hideSpinner() {
        spinnerCtrl(false);
        clearSpinnerTimeout();
      }
      function removeErrors() {
        errorsCtrl(false);
      }
      function setSpinnerName(name) {
        spinnerName = name;
      }
      function setErrorsNameOrCallback(nameOrCallback) {
        errorsNameOrCallback = nameOrCallback;
      }
      function closeModal() {
        modalInstance.close();
      }
      function extractErrors(resp) {
        var errors = resp.data && resp.data.errors && _.keys(resp.data).length === 1 ? resp.data.errors : resp.data;
        return _.isEmpty(errors) ? false : errors;
      }
      var spinnerTimeout;
      function clearSpinnerTimeout() {
        if (spinnerTimeout) {
          $timeout.cancel(spinnerTimeout);
        }
      }
      function enableSpinnerTimeout(timer) {
        spinnerTimeout = $timeout(function () {
          spinnerCtrl(true);
        }, timer);
      }
      function maybeHandleSpinnerWithTimer(timer) {
        if (timer) {
          enableSpinnerTimeout(timer);
          scope.$on("$destroy", clearSpinnerTimeout);
        } else {
          spinnerCtrl(true);
        }
      }
      return {
        applyToScope: function (name) {
          scope[name] = scope[name] || {};
          promise.then(function (value) {
            scope[name] = value;
          });
          return this;
        },
        getPromise: function () {
          return promise;
        },
        onSuccess: function (cb) {
          promise.then(cb);
          return this;
        },
        reloadState: function () {
          promise.then(function () {
            spinnerCtrl(true);
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
        showErrorsSensitiveSpinner: function (name, timer) {
          name && setSpinnerName(name);
          maybeHandleSpinnerWithTimer(timer);
          promise.then(null, hideSpinner);
          return this;
        },
        catchErrorsFromSuccess: function (nameOrCallback) {
          nameOrCallback && setErrorsNameOrCallback(nameOrCallback);
          promise.then(function (resp) {
            errorsCtrl(extractErrors(resp));
          });
          return this;
        },
        showSpinner: function (name, timer) {
          name && setSpinnerName(name);
          maybeHandleSpinnerWithTimer(timer);
          promise.then(hideSpinner, hideSpinner);
          return this;
        },
        catchErrors: function (nameOrCallback) {
          nameOrCallback && setErrorsNameOrCallback(nameOrCallback);
          promise.then(removeErrors, function (resp) {
            errorsCtrl(extractErrors(resp));
          });
          return this;
        },
        cleanPollCache: function (key) {
          promise.then(function () {
            mnPoll.cleanCache(key);
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
    }

    return mnPromiseHelper;
  });
