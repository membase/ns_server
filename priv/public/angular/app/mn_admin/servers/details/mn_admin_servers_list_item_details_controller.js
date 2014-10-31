angular.module('mnAdminServers')
  .controller('mnAdminServersListItemDetailsController',
    function ($scope, mnAdminServersListItemDetailsService) {
      $scope.$watch('node', function () {
        mnAdminServersListItemDetailsService.getNodeDetails($scope.node).then(function (details) {
          _.extend($scope, details);
        });
      });
    });