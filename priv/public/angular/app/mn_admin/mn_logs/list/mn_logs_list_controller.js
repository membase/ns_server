angular.module('mnLogs').controller('mnLogsListController',
  function ($scope, mnHelper, mnLogsService, logs) {
    function applyLogs(logs) {
      $scope.logs = logs.data.list;
    }

    applyLogs(logs);

    mnHelper.setupLongPolling({
      methodToCall: mnLogsService.getLogs,
      scope: $scope,
      onUpdate: applyLogs
    });

    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);

  }).filter('moduleCode', function () {
    return function (code) {
      return new String(1000 + parseInt(code)).slice(-3);
    };
  });