(function () {
  "use strict";

  angular
    .module('mnPromiseHelper', [
      'mnAlertsService',
      'mnHelper'
    ])
    .factory('mnPromiseHelper', mnPromiseHelperFactory);

  function mnPromiseHelperFactory(mnAlertsService, mnHelper, $timeout) {

    mnPromiseHelper.handleModalAction = handleModalAction;

    return mnPromiseHelper;

    function handleModalAction($scope, promise, $uibModalInstance, vm) {
      return mnPromiseHelper(vm || $scope, promise, $uibModalInstance)
        .showErrorsSensitiveSpinner()
        .closeFinally()
        .reloadState();
    }

    function mnPromiseHelper(scope, promise, modalInstance) {
      var spinnerNameOrFunction = 'viewLoading';
      var errorsNameOrCallback = 'errors';
      var spinnerTimeout;
      var promiseHelper = {
        applyToScope: applyToScope,
        getPromise: getPromise,
        onSuccess: onSuccess,
        reloadAndSwitchOnPoller: reloadAndSwitchOnPoller,
        reloadState: reloadState,
        closeFinally: closeFinally,
        closeOnSuccess: closeOnSuccess,
        showErrorsSensitiveSpinner: showErrorsSensitiveSpinner,
        catchErrorsFromSuccess: catchErrorsFromSuccess,
        showSpinner: showSpinner,
        catchErrors: catchErrors,
        catchGlobalErrors: catchGlobalErrors,
        showGlobalSuccess: showGlobalSuccess
      }

      return promiseHelper;

      function getPromise() {
        return promise;
      }
      function onSuccess(cb) {
        promise.then(cb);
        return this;
      }
      function reloadAndSwitchOnPoller(vm) {
        return mnPromiseHelper(scope, promise.then(function () {
          vm.poller.reload(vm)
          return vm.poller.doCallPromise;
        }), modalInstance);
      }
      function reloadState() {
        promise.then(function () {
          spinnerCtrl(true);
          mnHelper.reloadState();
        });
        return this;
      }
      function closeFinally() {
        promise['finally'](closeModal);
        return this;
      }
      function closeOnSuccess() {
        promise.then(closeModal);
        return this;
      }
      function showErrorsSensitiveSpinner(name, timer, scope) {
        name && setSpinnerName(name);
        maybeHandleSpinnerWithTimer(timer, scope);
        promise.then(null, hideSpinner);
        return this;
      }
      function catchErrorsFromSuccess(nameOrCallback) {
        nameOrCallback && setErrorsNameOrCallback(nameOrCallback);
        promise.then(function (resp) {
          errorsCtrl(extractErrors(resp));
        });
        return this;
      }
      function showSpinner(name, timer, scope) {
        name && setSpinnerName(name);
        maybeHandleSpinnerWithTimer(timer, scope);
        promise.then(hideSpinner, hideSpinner);
        return this;
      }
      function catchErrors(nameOrCallback) {
        nameOrCallback && setErrorsNameOrCallback(nameOrCallback);
        promise.then(removeErrors, function (resp) {
          errorsCtrl(extractErrors(resp));
        });
        return this;
      }
      function catchGlobalErrors(errorMessage, timeout) {
        promise.then(null, function (resp) {
          mnAlertsService.showAlertInPopup(errorMessage || extractErrors(resp.data), 'error', timeout);
        });
        return this;
      }
      function showGlobalSuccess(successMessage, timeout) {
        promise.then(function (resp) {
          mnAlertsService.showAlertInPopup(successMessage || resp.data, 'success', timeout);
        });
        return this;
      }
      function applyToScope(keyOrFunction) {
        promise.then(angular.isFunction(keyOrFunction) ? keyOrFunction : function (value) {
          scope[keyOrFunction] = value;
        }, function () {
          if (angular.isFunction(keyOrFunction)) {
            keyOrFunction(null);
          } else {
            delete scope[keyOrFunction];
          }
        });
        return this;
      }
      function spinnerCtrl(isLoaded) {
        if (angular.isFunction(spinnerNameOrFunction)) {
          spinnerNameOrFunction(isLoaded);
        } else {
          scope[spinnerNameOrFunction] = isLoaded;
        }
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
        spinnerNameOrFunction = name;
      }
      function setErrorsNameOrCallback(nameOrCallback) {
        errorsNameOrCallback = nameOrCallback;
      }
      function closeModal() {
        modalInstance.close(scope);
      }
      function extractErrors(resp) {
        if (resp.status === 0) {
          return false;
        }
        var errors = resp.data && resp.data.errors && _.keys(resp.data).length === 1 ? resp.data.errors : resp.data || resp ;
        return _.isEmpty(errors) ? false : errors;
      }
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
      function maybeHandleSpinnerWithTimer(timer, scope) {
        if (timer) {
          enableSpinnerTimeout(timer);
          scope.$on("$destroy", clearSpinnerTimeout);
        } else {
          spinnerCtrl(true);
        }
      }
    }
  }
})();
