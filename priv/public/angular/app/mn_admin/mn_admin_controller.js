angular.module('mnAdmin').controller('mnAdminController',
  function ($scope, $rootScope, $q, mnHelper, mnSettingsNotificationsService, mnPromiseHelper, pools, mnPoll, mnAuthService, mnTasksDetails, mnAlertsService, mnPoolDefault, mnSettingsAutoFailoverService) {
    $scope.launchpadId = pools.launchID;
    $scope.alerts = mnAlertsService.alerts;
    $scope.closeAlert = mnAlertsService.closeAlert;

    mnSettingsNotificationsService.maybeCheckUpdates().then(function (updates) {
      $scope.updates = updates;
      return updates.sendStats && mnSettingsNotificationsService.buildPhoneHomeThingy().then(function (launchpadSource) {
        $scope.launchpadSource = launchpadSource;
      });
    });

    $scope.logout = function () {
      mnAuthService.logout();
    };
    $scope.resetAutoFailOverCount = function () {
      mnPromiseHelper($scope, mnSettingsAutoFailoverService.resetAutoFailOverCount())
        .showSpinner('resetQuotaLoading')
        .catchGlobalErrors('Unable to reset the auto-failover quota!')
        .reloadState()
        .cancelOnScopeDestroy();
    };

    mnPoll
      .start($scope, function () {
        return $q.all([
          mnTasksDetails.get(),
          mnPoolDefault.getFresh()
        ])
      })
      .subscribe(function (resp) {
        $scope.tasks = resp[0];
        $rootScope.tabName = resp[1] && resp[1].clusterName;
      })
      .cancelOnScopeDestroy()
      .run();

  });