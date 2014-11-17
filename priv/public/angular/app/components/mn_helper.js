angular.module('mnHelper').factory('mnHelper',
  function ($window, $state, $stateParams) {
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
      if (isInfinitForSuccess) {
        if (promise.success) {
          return promise.error(hideSpinner);
        } else {
          return promise.then(null, hideSpinner);
        }
      } else {
        if (promise.success) {
          return promise.success(hideSpinner).error(hideSpinner);
        } else {
          return promise.then(hideSpinner, hideSpinner);
        }
      }
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
