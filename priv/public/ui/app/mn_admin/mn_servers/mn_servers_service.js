(function () {
  "use strict";

  angular
    .module('mnServersService', [
      'mnTasksDetails',
      'mnPoolDefault',
      'mnSettingsAutoFailoverService',
      'mnHttp',
      'ui.router',
      'mnSettingsClusterService',
      'mnGroupsService'
    ])
    .factory('mnServersService', mnServersFactory);

  function mnServersFactory(mnHttp, mnTasksDetails, mnPoolDefault, mnGroupsService, mnSettingsAutoFailoverService, $q, $state, $stateParams) {
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
      getServersState: getServersState,
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
      return mnHttp({
        method: 'POST',
        url: '/controller/setRecoveryType',
        data: data
      });
    }
    function setupServices(data) {
      return mnHttp({
        method: 'POST',
        url: '/node/controller/setupServices',
        data: data
      });
    }
    function cancelFailOverNode(data) {
      return mnHttp({
        method: 'POST',
        url: '/controller/reFailOver',
        data: data
      });
    }
    function stopRebalance() {
      return mnHttp({
        method: 'POST',
        url: '/controller/stopRebalance'
      });
    }
    function stopRecovery(url) {
      return mnHttp({
        method: 'POST',
        url: url
      });
    }
    function postFailover(type, otpNode) {
      return mnHttp({
        method: 'POST',
        url: '/controller/' + type,
        data: {otpNode: otpNode}
      });
    }
    function ejectNode(data) {
      return mnHttp({
        method: 'POST',
        url: '/controller/ejectNode',
        data: data
      });
    }
    function postRebalance(allNodes) {
      return mnHttp({
        method: 'POST',
        url: '/controller/rebalance',
        data: {
          knownNodes: _.pluck(allNodes, 'otpNode').join(','),
          ejectedNodes: _.pluck(mnServersService.getPendingEject(), 'otpNode').join(',')
        }
      });
    }
    function getNodeStatuses(hostname) {
      return mnHttp({
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
      return $q.all([
        mnPoolDefault.getFresh(),
        mnGroupsService.getGroups()
      ]).then(function (responses) {
        var groups = responses[1].groups;
        var poolDefault = responses[0];
        var nodes = poolDefault.nodes;

        if (poolDefault.isGroupsAvailable) {
          var hostnameToGroup = {};

          _.each(groups, function (group) {
            _.each(group.nodes, function (node) {
              hostnameToGroup[node.hostname] = group;
            });
          });

          nodes = _.map(nodes, function (n) {
            n = _.clone(n);
            var group = hostnameToGroup[n.hostname];
            if (group) {
              n.group = group.name;
            }
            return n;
          });
        }

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
    function getServersState(stateParamsNodeType) {
      return $q.all([
        mnServersService.getNodes(),
        mnPoolDefault.getFresh(),
        mnTasksDetails.get(),
        mnSettingsAutoFailoverService.getAutoFailoverSettings()
      ]).then(function (results) {

        var rv = {};
        var poolDefault = results[1];
        var nodes = results[0];
        var tasks = results[2];
        var autoFailoverSettings = results[3];
        rv.tasks = tasks;
        rv.nodes = nodes;
        rv.isGroupsAvailable = poolDefault.isGroupsAvailable;
        rv.currentNodes = nodes[stateParamsNodeType];
        rv.rebalancing = poolDefault.rebalancing;
        rv.pendingLength = nodes.pending.length;
        rv.mayRebalanceWithoutSampleLoading = !poolDefault.rebalancing && !tasks.inRecoveryMode && (!!nodes.pending.length || !poolDefault.balanced) && !nodes.unhealthyActive;
        rv.mayRebalance = rv.mayRebalanceWithoutSampleLoading && !tasks.isLoadingSampless && !tasks.isOrphanBucketTask;
        rv.showWarningMessage = rv.mayRebalanceWithoutSampleLoading && tasks.isLoadingSamples;
        rv.showPendingBadge = !rv.rebalancing && rv.pendingLength;
        rv.autoFailoverSettingsCount = autoFailoverSettings.data.count;
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
      return mnHttp({
        method: 'POST',
        url: (selectedGroup && selectedGroup.addNodeURI) || '/controller/addNode',
        data: credentials
      });
    }
  }
})();

