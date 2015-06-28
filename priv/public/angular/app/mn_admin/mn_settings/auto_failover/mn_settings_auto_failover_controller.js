angular.module('mnSettingsAutoFailover', [
  'mnSettingsAutoFailoverService',
  'mnHelper'
]).controller('mnSettingsAutoFailoverController',
  function ($scope, mnHelper, mnSettingsAutoFailoverService, autoFailoverSettings) {
    $scope.state = autoFailoverSettings.data
    $scope.submit = function () {
      var data = {
        enabled: $scope.state.enabled,
        timeout: $scope.state.timeout
      };
      mnHelper.promiseHelper($scope, mnSettingsAutoFailoverService.saveAutoFailoverSettings(data))
        .showErrorsSensitiveSpinner()
        .catchGlobalErrors('An error occured, auto-failover settings were not saved.')
        .reloadState();
    };
    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);
  });
