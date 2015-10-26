angular.module('mnSettingsAutoFailover', [
  'mnSettingsAutoFailoverService',
  'mnHelper',
  'mnPromiseHelper'
]).controller('mnSettingsAutoFailoverController',
  function ($scope, mnHelper, mnPromiseHelper, mnSettingsAutoFailoverService, mnPoolDefault) {

    $scope.mnPoolDefault = mnPoolDefault.latestValue();

    $scope.isAutoFailOverDisabled = function () {
      return !$scope.state || !$scope.state.enabled || $scope.mnPoolDefault.value.isROAdminCreds;
    }

    mnPromiseHelper($scope, mnSettingsAutoFailoverService.getAutoFailoverSettings())
      .applyToScope(function (autoFailoverSettings) {
        $scope.state = autoFailoverSettings.data
      })
      .cancelOnScopeDestroy();

    $scope.submit = function () {
      var data = {
        enabled: $scope.state.enabled,
        timeout: $scope.state.timeout
      };
      mnPromiseHelper($scope, mnSettingsAutoFailoverService.saveAutoFailoverSettings(data))
        .showErrorsSensitiveSpinner()
        .catchGlobalErrors('An error occured, auto-failover settings were not saved.')
        .reloadState()
        .cancelOnScopeDestroy();
    };
  });
