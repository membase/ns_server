angular.module('mnAdmin').controller('mnAdminController',
  function ($scope, mnHelper, $timeout, mnAuthService, tasks, mnTasksDetails) {

    $scope.logout = function () {
      mnAuthService.manualLogout().then(mnHelper.reloadApp);
    };

    $scope.tasks = tasks;

    var updateTasksCycle;
    (function updateTasks() {
      mnTasksDetails.getFresh().then(function (tasks) {
        $scope.tasks = tasks;
        updateTasksCycle = $timeout(updateTasks, tasks.recommendedRefreshPeriod);
      });
    })();

    $scope.$on('$destroy', function () {
      $timeout.cancel(updateTasksCycle);
    });

  });