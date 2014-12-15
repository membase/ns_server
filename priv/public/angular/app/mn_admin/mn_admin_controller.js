angular.module('mnAdmin').controller('mnAdminController',
  function ($scope, mnHelper, mnAuthService, tasks, mnTasksDetails) {

    $scope.logout = function () {
      mnAuthService.manualLogout().then(mnHelper.reloadApp);
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