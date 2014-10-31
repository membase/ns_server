angular.module('mnAdmin').controller('mnAdminController',
  function ($scope, $state, $location, $window, $timeout, mnAuthService, tasks, mnTasksDetails) {
    $scope.$state = $state;
    $scope.$location = $location;
    $scope._ = _;
    $scope.Math = Math;
    $scope.logout = function () {
      mnAuthService.manualLogout().then(function () {
        $window.location.reload();
      });
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