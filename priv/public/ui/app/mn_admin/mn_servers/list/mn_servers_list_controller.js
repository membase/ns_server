(function () {
  "use strict";

  angular
    .module("mnServers")
    .controller("mnServersListController", mnServersListController);

  function mnServersListController() {
    var vm = this;

    vm.sortByGroup = sortByGroup

    function sortByGroup(node) {
      return vm.getGroupsByHostname[node.hostname].name;
    }
  }
})();
