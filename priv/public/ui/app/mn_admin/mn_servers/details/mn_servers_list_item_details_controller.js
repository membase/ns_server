(function () {
  angular.module('mnServers')
    .controller('mnServersListItemDetailsController', mnServersListItemDetailsController)

    function mnServersListItemDetailsController($scope, mnServersListItemDetailsService, mnPromiseHelper) {
      var vm = this;
      $scope.$watch('this.node', function (node) {
        mnPromiseHelper(vm, mnServersListItemDetailsService.getNodeDetails(node))
          .applyToScope("server")
          .cancelOnScopeDestroy($scope);
      });
    }
})();