angular.module('mnSettingsAutoCompaction').controller('mnSettingsAutoCompactionController',
  function($scope, mnHelper, mnSettingsAutoCompactionService, autoCompactionSettings) {
    $scope.autoCompactionSettings = autoCompactionSettings;
    function getErrors(resp) {
      $scope.errors = resp.data.errors;
    }
    $scope.$watch('autoCompactionSettings', function (autoCompactionSettings) {
      mnSettingsAutoCompactionService
        .saveAutoCompaction(autoCompactionSettings, {just_validate: 1}).then(getErrors, getErrors);
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
