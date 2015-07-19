angular.module('mnLogs').controller('mnLogsListController',
  function ($scope, mnHelper, mnLogsService, logs, mnPoll) {
    function applyLogs(logs) {
      $scope.logs = logs.data.list;
    }

    applyLogs(logs);

    mnPoll.start($scope, function () {
      return mnLogsService.getLogs();
    }).subscribe(applyLogs);

    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);

  }).filter('moduleCode', function () {
    return function (code) {
      return new String(1000 + parseInt(code)).slice(-3);
    };
  });