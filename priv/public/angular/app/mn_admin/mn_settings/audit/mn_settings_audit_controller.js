angular.module('mnSettingsAudit', [
  'mnSettingsAuditService',
  'mnHelper',
  'mnPromiseHelper'
]).controller('mnSettingsAuditController',
  function ($scope, mnSettingsAuditService, auditSettings, mnPromiseHelper, mnHelper) {
    $scope.state = auditSettings;

    $scope.$watch('state', function (state) {
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
    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);
});
