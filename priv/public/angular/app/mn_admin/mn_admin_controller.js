angular.module('mnAdmin').controller('mnAdminController',
  function ($scope, $rootScope, $q, mnHelper, mnAuthService, tasks, mnTasksDetails, mnAlertsService, mnPoolDefault) {
    $scope.alerts = mnAlertsService.alerts;
    $scope.closeAlert = mnAlertsService.closeAlert;


    $scope.logout = function () {
      mnAuthService.logout();
    };

    function applyTasks(resp) {
      $scope.tasks = resp[0];
      $rootScope.tabName = resp[1] && resp[1].clusterName;
    }

    applyTasks(tasks);

    mnHelper.setupLongPolling({
      methodToCall: function () {
        return $q.all([
          mnTasksDetails.getFresh(),
          mnPoolDefault.getFresh()
        ]);
      },
      scope: $scope,
      onUpdate: applyTasks
    });
  });