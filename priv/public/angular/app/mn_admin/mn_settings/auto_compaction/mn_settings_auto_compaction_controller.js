angular.module('mnSettingsAutoCompaction', [
  'mnSettingsAutoCompactionService',
  'mnHelper',
  'mnPromiseHelper',
  'mnAutoCompactionForm'
]).controller('mnSettingsAutoCompactionController',
  function ($scope, mnHelper, mnPromiseHelper, mnSettingsAutoCompactionService) {
    mnPromiseHelper($scope, mnSettingsAutoCompactionService.getAutoCompaction()).applyToScope("autoCompactionSettings");

    $scope.$watch('autoCompactionSettings', function (autoCompactionSettings) {
      mnPromiseHelper($scope, mnSettingsAutoCompactionService
        .saveAutoCompaction(autoCompactionSettings, {just_validate: 1}))
        .catchErrors()
        .cancelOnScopeDestroy();
    }, true);

    $scope.submit = function () {
      if ($scope.viewLoading) {
        return;
      }
      mnPromiseHelper($scope, mnSettingsAutoCompactionService.saveAutoCompaction($scope.autoCompactionSettings))
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .reloadState()
        .cancelOnScopeDestroy();
    };
  });
