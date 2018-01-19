(function () {
  "use strict";

  angular.module('mnGsi', [
    'mnHelper',
    'mnGsiService',
    'mnSortableTable',
    'mnPoll',
    'mnSpinner',
    'mnFilters',
    'mnSearch',
    'mnElementCrane'
  ]).controller('mnGsiController', mnGsiController);

  function mnGsiController($scope, mnGsiService, mnHelper, mnPoller) {
    var vm = this;
    vm.generateIndexId = generateIndexId;
    vm.focusindexFilter = false;

    activate();

    function generateIndexId(row) {
      return (row.id.toString() + (row.instId || "")) + (row.hosts ? row.hosts.join() : "");
    }

    function activate() {
      mnHelper.initializeDetailsHashObserver(vm, 'openedIndex', 'app.admin.indexes.gsi');

      new mnPoller($scope, function () {
       return mnGsiService.getIndexesState();
      })
      .setInterval(10000)
      .subscribe("state", vm)
      .reloadOnScopeEvent("indexStatusURIChanged")
      .cycle();
    }
  }
})();
