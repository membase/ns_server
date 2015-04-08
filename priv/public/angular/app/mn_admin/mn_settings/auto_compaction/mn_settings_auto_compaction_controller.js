angular.module('mnSettingsAutoCompaction').controller('mnSettingsAutoCompactionController',
  function($scope, mnHelper, mnSettingsAutoCompactionService, autoCompactionSettings) {
    $scope.autoCompactionSettings = autoCompactionSettings;
    $scope.$watch('autoCompactionSettings', function (autoCompactionSettings) {
      mnHelper.promiseHelper($scope, mnSettingsAutoCompactionService
        .saveAutoCompaction(autoCompactionSettings, {just_validate: 1}))
        .catchErrors();
    }, true);
    $scope.submit = function () {
      if ($scope.viewLoading) {
        return;
      }
      mnHelper.promiseHelper($scope, mnSettingsAutoCompactionService.saveAutoCompaction($scope.autoCompactionSettings))
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .reloadState();
    };
  });
