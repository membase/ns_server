angular.module('mnSettingsNotifications').controller('mnSettingsNotificationsController',
  function ($scope, mnHelper, mnSettingsNotificationsService) {
    $scope.enabled = $scope.updates.sendStats;
    $scope.submit = function () {
      mnHelper
        .promiseHelper($scope, mnSettingsNotificationsService.saveSendStatsFlag($scope.enabled))
        .showErrorsSensitiveSpinner()
        .catchGlobalErrors('An error occured, update notifications settings were not saved.')
        .reloadState();
    };
    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);
  });
