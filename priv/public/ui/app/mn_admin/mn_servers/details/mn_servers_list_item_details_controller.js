(function () {
  "use strict";

  angular
    .module('mnServers')
    .controller('mnServersListItemDetailsController', mnServersListItemDetailsController)

    function mnServersListItemDetailsController($scope, mnServersListItemDetailsService, mnPromiseHelper) {
      var vm = this;
      $scope.$watch('this.node', function (node) {
        mnPromiseHelper(vm, mnServersListItemDetailsService.getNodeDetails(node))
          .applyToScope("server");
      });
      $scope.$watchGroup(['node', 'adminCtl.tasks'], function (values) {
        vm.tasks = mnServersListItemDetailsService.getNodeTasks(values[0], values[1]);
      });
    }
})();