angular.module('overview.service', ['app.service'])
  .factory('overview.service',
    ['$rootScope', 'app.service',
      function ($rootScope, appService) {
        var $scope = $rootScope.$new();

        $scope.model = {};

        function filterActiveNodes(node) {
          return node.clusterMembership === 'active' || node.clusterMembership === 'inactiveFailed';
        }

        function filterPendingNodes(node) {
          return node.clusterMembership !== 'active';
        }

        function filterFailedOverNodes(node) {
          return node.clusterMembership === 'inactiveFailed';
        }

        function filterDownNodes(node) {
          return node.status !== 'healthy';
        }

        appService.$watch('details.nodes', function (allNodes) {
          if (!allNodes) {
            return;
          }

          $scope.model.pendingNodesLength = _.filter(allNodes, filterPendingNodes).length;
          $scope.model.activeNodesLength = _.filter(allNodes, filterActiveNodes).length;
          $scope.model.failedOverNodesLength = _.filter(allNodes, filterFailedOverNodes).length;
          $scope.model.downNodesLength = _.filter(allNodes, filterDownNodes).length;
        });

        return $scope;
      }]);