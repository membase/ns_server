(function () {
  "use strict";

  angular.module('mnIndexes', [
    'mnHelper',
    'mnIndexesService',
    'mnSortableTable',
    'mnPoll',
    'mnSpinner'
  ]).controller('mnIndexesController', mnIndexesController);

  function mnIndexesController($scope, mnIndexesService, mnHelper, mnPoller) {
    var vm = this;

    activate();

    function activate() {
      mnHelper.initializeDetailsHashObserver(vm, 'openedIndex', 'app.admin.indexes');

      new mnPoller($scope, mnIndexesService.getIndexesState)
      .subscribe("mnIndexesState", vm)
      .keepIn("app.admin.indexes", vm)
      .cancelOnScopeDestroy()
      .cycle();
    }
  }
})();
