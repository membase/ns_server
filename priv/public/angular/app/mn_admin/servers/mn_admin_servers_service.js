angular.module('mnAdminServersService').factory('mnAdminServersService',
  function (mnAdminService, $http, $timeout, $rootScope) {
    var mnAdminServersService = {};

    mnAdminServersService.model = {};

    mnAdminServersService.populateModel = function (allNodes) {
      if (!allNodes) {
        return;
      }

      mnAdminServersService.model.pendingNodes = _.filter(allNodes, filterPendingNodes);
      mnAdminServersService.model.activeNodes = _.filter(allNodes, filterActiveNodes);
      mnAdminServersService.model.failedOverNodes = _.filter(allNodes, filterFailedOverNodes);
      mnAdminServersService.model.downNodes = _.filter(allNodes, filterDownNodes);
    };

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

    return mnAdminServersService;
  });
