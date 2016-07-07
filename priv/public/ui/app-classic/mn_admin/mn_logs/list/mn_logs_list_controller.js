(function () {
  "use strict";

  angular
    .module('mnLogs')
    .controller('mnLogsListController', mnLogsListController)
    .filter('moduleCode', moduleCodeFilter);

  function mnLogsListController($scope, mnLogsService, mnPoller)  {
    var vm = this;
    var openedByIndex = {};
    var textLimit = 1000;

    vm.toggle = toggle;
    vm.textLimit = textLimit;
    vm.isOpened = isOpened;
    vm.isOverLimit = isOverLimit;

    activate();

    function activate() {
      new mnPoller($scope, mnLogsService.getLogs)
      .subscribe(function (logs) {
        vm.logs = logs.data.list;
      })
      .setInterval(10000)
      .cycle();
    }
    function getOriginalLogItemIndex(index) {
      //because after orderBy:'serverTime':true we have reversed list
      //but we have to track items by their original index in order
      //to keep details open
      return vm.logs.length - (index + 1);
    }
    function isOverLimit(row) {
      return row.text.length > textLimit;
    }
    function toggle(index) {
      var originalIndex = getOriginalLogItemIndex(index);
      openedByIndex[originalIndex] = !openedByIndex[originalIndex];
    }
    function isOpened(index) {
      return openedByIndex[getOriginalLogItemIndex(index)];
    }
  }

  function moduleCodeFilter() {
    return function (code) {
      return new String(1000 + parseInt(code)).slice(-3);
    };
  }
})();
