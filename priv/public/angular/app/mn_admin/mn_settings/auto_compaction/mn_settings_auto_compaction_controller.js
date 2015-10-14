angular.module('mnSettingsAutoCompaction', [
  'mnSettingsAutoCompactionService',
  'mnHelper',
  'mnPromiseHelper',
  'mnAutoCompactionForm',
  'mnPoolDefault'
]).controller('mnSettingsAutoCompactionController',
  function ($scope, mnHelper, mnPromiseHelper, mnSettingsAutoCompactionService, mnPoolDefault) {
    mnPromiseHelper($scope, mnSettingsAutoCompactionService.getAutoCompaction()).applyToScope("autoCompactionSettings");

    $scope.mnPoolDefault = mnPoolDefault.latestValue();

    if ($scope.mnPoolDefault.isROAdminCreds) {
      return;
    }
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
