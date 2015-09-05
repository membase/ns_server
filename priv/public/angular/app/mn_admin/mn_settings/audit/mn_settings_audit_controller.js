angular.module('mnSettingsAudit', [
  'mnSettingsAuditService',
  'mnHelper',
  'mnPromiseHelper'
]).controller('mnSettingsAuditController',
  function ($scope, mnSettingsAuditService, mnPromiseHelper, mnHelper) {

    mnPromiseHelper($scope, mnSettingsAuditService.getAuditSettings()).applyToScope("state");

    $scope.$watch('state', function (state) {
      if (!state) {
        return;
      }
      mnPromiseHelper($scope, mnSettingsAuditService.saveAuditSettings(state, true))
        .catchErrorsFromSuccess();
    }, true);

    $scope.submit = function () {
      if ($scope.viewLoading) {
        return;
      }
      mnPromiseHelper($scope, mnSettingsAuditService.saveAuditSettings($scope.state))
        .catchErrorsFromSuccess()
        .showSpinner()
        .reloadState();
    };
});
