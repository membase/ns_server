angular.module('mnAdminServersService').factory('mnAdminServersService',
  function ($http, $q, mnAdminService) {
    var mnAdminServersService = {};

    mnAdminServersService.model = {};

    mnAdminServersService.onStopRebalance = function (url) {
      return $http({method: 'POST', url: url});
    };

    mnAdminServersService.postAndReload = function (url, data) {
      var params = {
        method: 'POST',
        url: url,
        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
      };
      data && (params.data = _.serializeData(data));
      return $http(params).success(mnAdminService.runDefaultPoolsDetailsLoop);
    };

    mnAdminServersService.populatePerNodeRepalanceProgress = function (deps) {
      if (!deps) {
        return;
      }

      if (!deps.progress || deps.progress.status !== 'running') {
        _.each(deps.nodes, function (node) {
          node.rebalanceProgressPercent = 0;
        });
        return;
      }

      _.each(deps.nodes, function (node) {
        var progress = deps.progress.perNode[node.otpNode];
        if (!progress) {
          return;
        }
        node.rebalanceProgressPercent = _.truncateTo3Digits(progress.progress);
      });
    };

    mnAdminServersService.populateNodesModel = function (nodesModelDeps) {
      if (!nodesModelDeps || !nodesModelDeps.hostnameToGroup) {
        return;
      }

      var hostnameToGroup = (nodesModelDeps.isGroupsAvailable && nodesModelDeps.hostnameToGroup) || {};

      var nodes = _.map(nodesModelDeps.nodes, function (n) {
        n = _.clone(n);
        var group = hostnameToGroup[n.hostname];
        if (group) {
          n.group = group.name;
        }
        return n;
      });

      var stillActualEject = [];

      _.each(nodesModelDeps.pendingEject, function (node) {
        var original = _.detect(nodes, function (n) {
          return n.otpNode == node.otpNode;
        });
        if (!original || original.clusterMembership === 'inactiveAdded') {
          return;
        }
        stillActualEject.push(original);
        original.pendingEject = true;
      });

      nodesModelDeps.pendingEject = stillActualEject;

      var rv = {};

      rv.allNodes = nodes;

      rv.failedOver = _.filter(nodes, isFailedOverNode);

      rv.onlyActive = _.filter(nodes, isActiveNode);

      rv.active = rv.failedOver.concat(rv.onlyActive);

      rv.down = _.filter(nodes, function (node) {
        return !isHealthyNode(node);
      });

      rv.pending = _.filter(nodes, function (node) {
        return !isActiveNode(node);
      }).concat(nodesModelDeps.pendingEject);

      rv.reallyActive = _.filter(rv.onlyActive, function (node) {
        return !isPendingEjectNode(node);
      });

      rv.unhealthyActive = _.detect(rv.reallyActive, function (node) {
        return isUnhealthyNode(node);
      });

      mnAdminServersService.model.nodes = rv;
    };

    mnAdminServersService.populateFailoverWarningsModel = function (failoverWarnings) {
      mnAdminServersService.model.failoverWarnings = _.map(failoverWarnings, convertFailoverWarnings);
    };

    mnAdminServersService.populateRebalanceModel = function (data) {
      if (!data) {
        return;
      }

      mnAdminServersService.model.rebalancing = data.rebalanceStatus != 'none';


      mnAdminServersService.model.mayRebalanceWithoutSampleLoading =
        !mnAdminServersService.model.rebalancing && !data.inRecoveryMode &&
        (!!data.pendingNodes.length || !data.balanced) && !data.unhealthyActiveNodes;

      mnAdminServersService.model.mayRebalance = mnAdminServersService.model.mayRebalanceWithoutSampleLoading && !data.isLoadingSamples;
    };


    function convertFailoverWarnings(failoverWarning) {
      switch (failoverWarning) {
        case 'failoverNeeded': return;
        case 'rebalanceNeeded': return 'Rebalance required, some data is not currently replicated!';
        case 'hardNodesNeeded': return 'At least two servers are required to provide replication!';
        case 'softNodesNeeded': return 'Additional active servers required to provide the desired number of replicas!';
        case 'softRebalanceNeeded': return 'Rebalance recommended, some data does not have the desired replicas configuration!';
      }
    }

    function isActiveNode(node) {
      return node.clusterMembership === 'active';
    }
    function isPendingEjectNode(node) {
      return node.pendingEject;
    }
    function isUnhealthyNode(node) {
      return node.status === 'unhealthy';
    }
    function isHealthyNode(node) {
      return node.status === 'healthy';
    }
    function isFailedOverNode(node) {
      return node.clusterMembership === 'inactiveFailed';
    }

    return mnAdminServersService;
  });
