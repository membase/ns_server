(function () {
  "use strict";

  angular
    .module('mnServersService', [
      'mnPoolDefault',
      'ui.router',
      'mnSettingsClusterService',
      'mnGroupsService'
    ])
    .factory('mnServersService', mnServersFactory);

  function mnServersFactory($http, $q, mnPoolDefault, mnGroupsService, $state, $stateParams) {
    var pendingEject = [];

    var mnServersService = {
      addToPendingEject: addToPendingEject,
      removeFromPendingEject: removeFromPendingEject,
      getPendingEject: getPendingEject,
      setPendingEject: setPendingEject,
      reAddNode: reAddNode,
      setupServices: setupServices,
      cancelFailOverNode: cancelFailOverNode,
      stopRebalance: stopRebalance,
      stopRecovery: stopRecovery,
      postFailover: postFailover,
      ejectNode: ejectNode,
      postRebalance: postRebalance,
      getNodeStatuses: getNodeStatuses,
      getNodes: getNodes,
      addServer: addServer
    };

    return mnServersService;

    function addToPendingEject(node) {
      pendingEject.push(node);
    }
    function removeFromPendingEject(node) {
      node.pendingEject = false;
      _.remove(pendingEject, {'hostname': node.hostname});
    }
    function getPendingEject() {
      return pendingEject;
    }
    function setPendingEject(newPendingEject) {
      pendingEject = newPendingEject;
    }
    function reAddNode(data) {
      return $http({
        method: 'POST',
        url: '/controller/setRecoveryType',
        data: data
      });
    }
    function setupServices(data) {
      return $http({
        method: 'POST',
        url: '/node/controller/setupServices',
        data: data
      });
    }
    function cancelFailOverNode(data) {
      return $http({
        method: 'POST',
        url: '/controller/reFailOver',
        data: data
      });
    }
    function stopRebalance() {
      return $http({
        method: 'POST',
        url: '/controller/stopRebalance'
      });
    }
    function stopRecovery(url) {
      return $http({
        method: 'POST',
        url: url
      });
    }
    function postFailover(type, otpNode) {
      return $http({
        method: 'POST',
        url: '/controller/' + type,
        data: {otpNode: otpNode}
      });
    }
    function ejectNode(data) {
      return $http({
        method: 'POST',
        url: '/controller/ejectNode',
        data: data
      });
    }
    function postRebalance(allNodes) {
      return $http({
        method: 'POST',
        url: '/controller/rebalance',
        data: {
          knownNodes: _.pluck(allNodes, 'otpNode').join(','),
          ejectedNodes: _.pluck(mnServersService.getPendingEject(), 'otpNode').join(',')
        }
      }).then(null, function (resp) {
        if (resp.data) {
          if (resp.data.mismatch) {
            resp.data.mismatch = "Could not Rebalance because the cluster configuration was modified by someone else.\nYou may want to verify the latest cluster configuration and, if necessary, please retry a Rebalance.";
          }
          if (resp.data.deltaRecoveryNotPossible) {
            resp.data.deltaRecoveryNotPossible = "Could not Rebalance because requested delta recovery is not possible. You probably added more nodes to the cluster or changed server groups configuration.";
          }
          if (resp.data.noKVNodesLeft) {
            resp.data.noKVNodesLeft = "Could not Rebalance out last kv node(s).";
          }
        } else {
          resp.data = "Request failed. Check logs.";
        }
        return $q.reject(resp);
      });
    }
    function getNodeStatuses(hostname) {
      return $http({
        method: 'GET',
        url: '/nodeStatuses'
      }).then(function (resp) {
        var nodeStatuses = resp.data;
        var node = nodeStatuses[hostname];
        if (!node) {
          return
        }
        var rv = _.clone(node);
        rv.confirmation = false;
        rv.down = node.status != 'healthy';
        rv.backfill = node.replication < 1;
        rv.failOver = rv.down ? "failOver" : node.gracefulFailoverPossible ? "startGracefulFailover" : "failOver";
        rv.gracefulFailoverPossible = node.gracefulFailoverPossible;
        rv.down && (rv.failOver = 'failOver');
        !rv.backfill && (rv.confirmation = true);
        return rv;
      })
    }
    function getNodes() {
      return mnPoolDefault.get().then(function (poolDefault) {
        var nodes = poolDefault.nodes;

        var stillActualEject = [];

        _.each(mnServersService.getPendingEject(), function (node) {
          var original = _.detect(nodes, function (n) {
            return n.otpNode == node.otpNode;
          });
          if (!original || original.clusterMembership === 'inactiveAdded') {
            return;
          }
          stillActualEject.push(original);
          original.pendingEject = true;
        });

        mnServersService.setPendingEject(stillActualEject);

        var rv = {};

        rv.allNodes = nodes;

        rv.failedOver = _.filter(nodes, function (node) {
          return node.clusterMembership === 'inactiveFailed';
        });
        rv.onlyActive = _.filter(nodes, function (node) {
          return node.clusterMembership === 'active';
        });
        rv.active = rv.failedOver.concat(rv.onlyActive);
        rv.down = _.filter(nodes, function (node) {
          return node.status !== 'healthy';
        });
        rv.pending = _.filter(nodes, function (node) {
          return node.clusterMembership !== 'active';
        }).concat(mnServersService.getPendingEject());
        rv.reallyActive = _.filter(rv.onlyActive, function (node) {
          return !node.pendingEject
        });
        rv.reallyActiveData = _.filter(rv.reallyActive, function (node) {
          return _.indexOf(node.services, "kv") > -1;
        });
        rv.unhealthyActive = _.detect(rv.reallyActive, function (node) {
          return node.status === 'unhealthy';
        });
        rv.ramTotalPerActiveNode = poolDefault.storageTotals.ram.total / rv.onlyActive.length;

        return rv;
      });
    }
    function addServer(selectedGroup, credentials, servicesList) {
      credentials = _.clone(credentials);
      if (!credentials['user'] || !credentials['password']) {
        credentials['user'] = '';
        credentials['password'] = '';
      }
      credentials.services = servicesList.join(',');
      return $http({
        method: 'POST',
        url: (selectedGroup && selectedGroup.addNodeURI) || '/controller/addNode',
        data: credentials
      });
    }
  }
})();

