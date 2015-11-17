(function () {
  "use strict";

  angular
    .module('mnLogs')
    .controller('mnLogsListController', mnLogsListController)
    .filter('moduleCode', moduleCodeFilter);

  function mnLogsListController($scope, mnLogsService, mnPoller)  {
    var vm = this;

    activate();

    function activate() {
      new mnPoller($scope, mnLogsService.getLogs)
      .subscribe(function (logs) {
        vm.logs = logs.data.list;
      })
      .keepIn("app.admin.logs", vm)
      .cancelOnScopeDestroy()
      .cycle();
    }
  }

  function moduleCodeFilter() {
    return function (code) {
      return new String(1000 + parseInt(code)).slice(-3);
    };
  }
})();
