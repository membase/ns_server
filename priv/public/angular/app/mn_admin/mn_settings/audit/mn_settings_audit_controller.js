angular.module('mnSettingsAudit', [
  'mnSettingsAuditService',
  'mnHelper'
]).controller('mnSettingsAuditController',
  function ($scope, mnSettingsAuditService, auditSettings, mnHelper) {
    $scope.state = auditSettings;

    $scope.$watch('state', function (state) {
      mnHelper.promiseHelper($scope, mnSettingsAuditService.saveAuditSettings(state, true))
        .catchErrorsFromSuccess();
    }, true);

    $scope.submit = function () {
      if ($scope.viewLoading) {
        return;
      }
      mnHelper.promiseHelper($scope, mnSettingsAuditService.saveAuditSettings($scope.state))
        .catchErrorsFromSuccess()
        .showSpinner()
        .reloadState();
    };
    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);
});
