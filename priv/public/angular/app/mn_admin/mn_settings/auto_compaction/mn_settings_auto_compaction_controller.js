angular.module('mnSettingsAutoCompaction', [
  'mnSettingsAutoCompactionService',
  'mnHelper',
  'mnPromiseHelper',
  'mnAutoCompactionForm'
]).controller('mnSettingsAutoCompactionController',
  function ($scope, mnHelper, mnPromiseHelper, mnSettingsAutoCompactionService, autoCompactionSettings) {
    $scope.autoCompactionSettings = autoCompactionSettings;
    $scope.$watch('autoCompactionSettings', function (autoCompactionSettings) {
      mnPromiseHelper($scope, mnSettingsAutoCompactionService
        .saveAutoCompaction(autoCompactionSettings, {just_validate: 1}))
        .catchErrors();
    }, true);
    $scope.submit = function () {
      if ($scope.viewLoading) {
        return;
      }
      mnPromiseHelper($scope, mnSettingsAutoCompactionService.saveAutoCompaction($scope.autoCompactionSettings))
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .reloadState();
    };
    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);
  });
