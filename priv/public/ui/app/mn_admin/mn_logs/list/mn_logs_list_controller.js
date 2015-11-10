angular.module('mnLogs').controller('mnLogsListController',
  function ($scope, mnHelper, mnLogsService, mnPoller) {

    new mnPoller($scope, mnLogsService.getLogs)
      .subscribe(function (logs) {
        $scope.logs = logs.data.list;
      })
      .keepIn("app.admin.logs")
      .cancelOnScopeDestroy()
      .cycle();


  }).filter('moduleCode', function () {
    return function (code) {
      return new String(1000 + parseInt(code)).slice(-3);
    };
  });