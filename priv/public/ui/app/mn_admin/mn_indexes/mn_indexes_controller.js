(function () {
  "use strict";

  angular
    .module("mnIndexes")
    .controller("mnIndexesController", mnIndexesController);

  function mnIndexesController(mnPluggableUiRegistry) {
    var vm = this;
    vm.pluggableUiConfigs = mnPluggableUiRegistry.getConfigs();
  }
})();
