angular.module('mnAdmin').controller('mnAdminController',
  function ($scope, mnHelper, mnAuthService, tasks, mnTasksDetails, mnAlertsService) {

    $scope.alerts = mnAlertsService.alerts;
    $scope.closeAlert = mnAlertsService.closeAlert;

    $scope.logout = function () {
      mnAuthService.logout();
    };

    function applyTasks(tasks) {
      $scope.tasks = tasks;
    }

    applyTasks(tasks);

    mnHelper.setupLongPolling({
      methodToCall: mnTasksDetails.getFresh,
      scope: $scope,
      onUpdate: applyTasks
    });
  });