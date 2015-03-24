angular.module('mnSettingsAudit').controller('mnSettingsAuditController',
  function ($scope, mnSettingsAuditService, auditSettings, mnHelper) {
    $scope.state = auditSettings;

    $scope.$watch('state', function() {
      if ($scope.state.auditdEnabled) {
        mnHelper.promiseHelper($scope, mnSettingsAuditService.saveAuditSettings($scope.state, true))
          .catchErrorsFromSuccess();
      } else {
        $scope.errors = null;
      }
    }, true);

    $scope.submit = function() {
      if ($scope.viewLoading) {
        return;
      }
      mnHelper.promiseHelper($scope, mnSettingsAuditService.saveAuditSettings($scope.state))
        .catchErrorsFromSuccess()
        .showSpinner('viewLoading');
    };
});
