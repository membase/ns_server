angular.module('mnSettingsAudit', [
  'mnSettingsAuditService',
  'mnHelper',
  'mnPromiseHelper',
  'mnPoolDefault'
]).controller('mnSettingsAuditController',
  function ($scope, mnSettingsAuditService, mnPromiseHelper, mnHelper, mnPoolDefault) {

    mnPromiseHelper($scope, mnSettingsAuditService.getAuditSettings()).applyToScope("state");

    $scope.mnPoolDefault = mnPoolDefault.latestValue();

    if ($scope.mnPoolDefault.isROAdminCreds) {
      return;
    }

    $scope.$watch('state', function (state) {
      if (!state) {
        return;
      }
      mnPromiseHelper($scope, mnSettingsAuditService.saveAuditSettings(state, true))
        .catchErrorsFromSuccess()
        .cancelOnScopeDestroy();
    }, true);

    $scope.submit = function () {
      if ($scope.viewLoading) {
        return;
      }
      mnPromiseHelper($scope, mnSettingsAuditService.saveAuditSettings($scope.state))
        .catchErrorsFromSuccess()
        .showSpinner()
        .reloadState()
        .cancelOnScopeDestroy();
    };
});
