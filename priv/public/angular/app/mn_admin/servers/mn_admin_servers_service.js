angular.module('mnAdminServersService').factory('mnAdminServersService',
  function ($http, $q, mnAdminService) {
    var mnAdminServersService = {};

    mnAdminServersService.model = {};

    mnAdminServersService.onStopRebalance = function (url) {
      return $http({method: 'POST', url: url});
    };

    //TODO: move it to the AutoFailoverSettings section
    var resetAutoFailOverCountCanceler;
    mnAdminServersService.resetAutoFailOverCount = function () {
      resetAutoFailOverCountCanceler && resetAutoFailOverCountCanceler.resolve();
      resetAutoFailOverCountCanceler = $q.defer();

      return $http({
        method: 'POST',
        url: '/settings/autoFailover/resetCount',
        timeout: resetAutoFailOverCountCanceler.promise
      });
    };

    //TODO: move it to the AutoFailoverSettings section
    mnAdminServersService.getAutoFailoverSettings = function (url) {
      return $http({method: 'GET', url: "/settings/autoFailover"});
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

      rv = {
        pending: _.filter(nodes, filterPendingNodes).concat(nodesModelDeps.pendingEject),
        active: _.filter(nodes, filterActiveNodes),
        failedOver: _.filter(nodes, filterFailedOverNodes),
        down: _.filter(nodes, filterDownNodes),
        allNodes: nodes
      };

      rv.reallyActive = _.filter(rv.active, filterReallyActiveNodes);

      rv.unhealthyActive = _.detect(rv.active, unhealthyActiveNodes);

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

    function filterReallyActiveNodes(n) {
      return n.clusterMembership === 'active' && !n.pendingEject;
    }

    function unhealthyActiveNodes(n) {
      return n.clusterMembership == 'active' && !n.pendingEject && n.status === 'unhealthy';
    }

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
