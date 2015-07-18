angular.module('mnSettingsNotifications', [
  'mnSettingsNotificationsService',
  'mnHelper',
  'mnPromiseHelper'
]).controller('mnSettingsNotificationsController',
  function ($scope, mnHelper, mnPromiseHelper, mnSettingsNotificationsService) {
    $scope.enabled = $scope.updates.sendStats;
    $scope.submit = function () {
      mnPromiseHelper($scope, mnSettingsNotificationsService.saveSendStatsFlag($scope.enabled))
        .showErrorsSensitiveSpinner()
        .catchGlobalErrors('An error occured, update notifications settings were not saved.')
        .reloadState();
    };
    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);
  });
