(function () {
  "use strict";

  angular.module('mnGsi', [
    'mnHelper',
    'mnGsiService',
    'mnSortableTable',
    'mnPoll',
    'mnSpinner'
  ]).controller('mnGsiController', mnGsiController);

  function mnGsiController($scope, mnGsiService, mnHelper, mnPoller) {
    var vm = this;

    activate();

    function activate() {
      mnHelper.initializeDetailsHashObserver(vm, 'openedIndex', 'app.admin.indexes.gsi');

      new mnPoller($scope, function () {
       return mnGsiService.getIndexesState();
      })
      .subscribe("state", vm)
      .cycle();
    }
  }
})();
