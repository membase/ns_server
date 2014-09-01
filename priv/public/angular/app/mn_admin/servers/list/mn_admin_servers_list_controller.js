angular.module('mnAdminServers').controller('mnAdminServersListController',
  function ($scope, $stateParams, mnAdminServersService) {
    $scope.$watch(function () {
      var nodes = mnAdminServersService.model.nodes;
      return nodes && nodes[$stateParams.list];
    }, function (nodes) {
      $scope.nodesList = nodes;
    });
  });