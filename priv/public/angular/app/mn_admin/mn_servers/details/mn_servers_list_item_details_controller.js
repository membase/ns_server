angular.module('mnServers')
  .controller('mnServersListItemDetailsController',
    function ($scope, mnServersListItemDetailsService, mnPromiseHelper) {
      $scope.$watch('node', function () {
        mnPromiseHelper($scope, mnServersListItemDetailsService.getNodeDetails($scope.node))
          .applyToScope("server")
          .cancelOnScopeDestroy();
      });
    });