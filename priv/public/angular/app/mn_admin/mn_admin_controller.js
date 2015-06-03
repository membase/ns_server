angular.module('mnAdmin').controller('mnAdminController',
  function ($scope, $rootScope, $q, mnHelper, pools, mnAuthService, tasks, updates, mnTasksDetails, mnAlertsService, mnPoolDefault, launchpadSource, mnSettingsAutoFailoverService) {
    $scope.launchpadId = pools.launchID;
    $scope.launchpadSource = launchpadSource;
    $scope.updates = updates;
    $scope.alerts = mnAlertsService.alerts;
    $scope.closeAlert = mnAlertsService.closeAlert;


    $scope.logout = function () {
      mnAuthService.logout();
    };
    $scope.resetAutoFailOverCount = function () {
      mnHelper.promiseHelper($scope, mnSettingsAutoFailoverService.resetAutoFailOverCount())
        .showSpinner('resetQuotaLoading')
        .catchGlobalErrors('Unable to reset the auto-failover quota!')
        .reloadState();
    };

    function applyTasks(resp) {
      $scope.tasks = resp[0];
      $rootScope.tabName = resp[1] && resp[1].clusterName;
    }

    applyTasks(tasks);

    mnHelper.setupLongPolling({
      methodToCall: function () {
        return $q.all([
          mnTasksDetails.getFresh({httpGroup: 'globals'}),
          mnPoolDefault.getFresh({httpGroup: 'globals'})
        ]);
      },
      scope: $scope,
      onUpdate: applyTasks
    });

    mnHelper.cancelAllHttpOnScopeDestroy($scope);
  });