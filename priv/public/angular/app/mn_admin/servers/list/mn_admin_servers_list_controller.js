angular.module('mnAdminServers').controller('mnAdminServersListController',
  function ($scope, $stateParams, mnAdminService, mnAdminServersService) {
    $scope.$watch(function () {
      var nodes = mnAdminService.model.nodes;
      return nodes && nodes[$stateParams.list];
    }, function (nodes) {
      $scope.nodesList = nodes;
    });
  });