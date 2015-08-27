angular.module('mnPromiseHelper', [
  'mnAlertsService',
  'mnHelper'
]).factory('mnPromiseHelper',
  function (mnAlertsService, mnHelper, mnPoll) {

    mnPromiseHelper.handleModalAction = function ($scope, promise, $modalInstance) {
      return mnPromiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .closeFinally()
        .reloadState();
    };

    function mnPromiseHelper(scope, promise, modalInstance) {
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
        var errors = resp.data && resp.data.errors && _.keys(resp.data).length === 1 ? resp.data.errors : resp.data;
        return _.isEmpty(errors) ? false : errors;
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
