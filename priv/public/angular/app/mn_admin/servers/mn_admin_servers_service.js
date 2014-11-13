angular.module('mnAdminServersService').factory('mnAdminServersService',
  function (mnHttp, mnTasksDetails, mnPoolDefault, $q, $state, $stateParams, mnHelper) {
    var mnAdminServersService = {};

    var pendingEject = [];

    mnAdminServersService.addToPendingEject = function (node) {
      pendingEject.push(node);
    };
    mnAdminServersService.removeFromPendingEject = function (node) {
      node.pendingEject = false;
      _.remove(pendingEject, {'hostname': node.hostname});
    };
    mnAdminServersService.getPendingEject = function () {
      return pendingEject;
    };
    mnAdminServersService.setPendingEject = function (newPendingEject) {
      pendingEject = newPendingEject;
    };

    mnAdminServersService.initializeServices = function ($scope) {
      $scope.services = {
        kv: true
      };

      $scope.$watch(function () {
        return mnHelper.checkboxesToList($scope.services);
      }, function (services) {
        $scope.servicesWarning = services.length > 1;
      }, true);
    };

    mnAdminServersService.reAddNode = function (data) {
      return mnHttp({
        method: 'POST',
        url: '/controller/setRecoveryType',
        data: data
      });
    };
    mnAdminServersService.getGroups = function () {
      return mnHttp({
        method: 'GET',
        url: '/pools/default/serverGroups'
      }).then(function (resp) {
        return resp.data;
      })
    };
    mnAdminServersService.setupServices = function (data) {
      return mnHttp({
        method: 'POST',
        url: '/node/controller/setupServices',
        data: data
      });
    };
    mnAdminServersService.cancelFailOverNode = function (data) {
      return mnHttp({
        method: 'POST',
        url: '/controller/reFailOver',
        data: data
      });
    };
    mnAdminServersService.stopRebalance = function () {
      return mnHttp({
        method: 'POST',
        url: '/controller/stopRebalance'
      });
    };
    mnAdminServersService.stopRecovery = function (url) {
      return mnHttp({
        method: 'POST',
        url: url
      });
    };
    mnAdminServersService.postFailover = function (type, otpNode) {
      return mnHttp({
        method: 'POST',
        url: '/controller/' + type,
        data: {otpNode: otpNode}
      });
    };
    mnAdminServersService.ejectNode = function (data) {
      return mnHttp({
        method: 'POST',
        url: '/controller/ejectNode',
        data: data
      });
    };
    mnAdminServersService.postRebalance = function (allNodes) {
      return mnHttp({
        method: 'POST',
        url: '/controller/rebalance',
        data: {
          knownNodes: _.pluck(allNodes, 'otpNode').join(','),
          ejectedNodes: _.pluck(mnAdminServersService.getPendingEject(), 'otpNode').join(',')
        }
      });
    };
    mnAdminServersService.getNodeStatuses = function (hostname) {
      return mnHttp({
        method: 'GET',
        url: '/nodeStatuses'
      }).then(function (resp) {
        var nodeStatuses = resp.data;
        var node = nodeStatuses[hostname];
        if (!node) {
          return
        }
        var rv = {}
        rv.confirmation = false;
        rv.down = node.status != 'healthy';
        rv.backfill = node.replication < 1;
        rv.failOver = node.gracefulFailoverPossible ? "startGracefulFailover" : "failOver";
        rv.gracefulFailoverPossible = node.gracefulFailoverPossible;
        rv.down && (rv.failOver = 'failOver');
        !rv.backfill && (rv.confirmation = true);
        return rv;
      })
    };

    function prepareNode(nodes, tasks, stateParamsNodeType) {
      return _.map(nodes[stateParamsNodeType], function (node) {
        node.couchDataSize = _.formatQuantity(node.interestingStats['couch_docs_data_size'] + node.interestingStats['couch_views_data_size']);
        node.couchDiskUsage = _.formatQuantity(node.interestingStats['couch_docs_actual_disk_size'] + node.interestingStats['couch_views_actual_disk_size']);
        node.currItems = _.formatQuantity(node.interestingStats['curr_items'] || 0, 1000, ' ');
        node.currVbItems = _.formatQuantity(node.interestingStats['vb_replica_curr_items'] || 0, 1000, ' ');
        node.isDataDiskUsageAvailable = !!(node.couchDataSize && node.couchDiskUsage);
        node.isNodeUnhealthy = node.status === 'unhealthy';
        node.isNodeInactiveFaied = node.clusterMembership === 'inactiveFailed';
        node.isNodeInactiveAdded = node.clusterMembership === 'inactiveAdded';
        node.isReAddPossible = node.isNodeInactiveFaied && !node.isNodeUnhealthy;
        node.isLastActive = nodes.reallyActive.length === 1;
        node.isActiveUnhealthy = stateParamsNodeType === "active" && node.isNodeUnhealthy;
        node.safeNodeOtpNode = _.makeSafeForCSS(node.otpNode);
        node.strippedPort = _.stripPortHTML(node.hostname, nodes.allNodes);

        var rebalanceProgress = tasks.tasksRebalance.perNode && tasks.tasksRebalance.perNode[node.otpNode];
        node.rebalanceProgress = rebalanceProgress ? _.truncateTo3Digits(rebalanceProgress.progress) : 0 ;

        var total = node.memoryTotal;
        var free = node.memoryFree;

        node.ramUsageConf = {
          exist: (total > 0) && _.isFinite(free),
          height: (total - free) / total * 100,
          top: 105 - ((total - free) / total * 100),
          value: _.truncateTo3Digits((total - free) / total * 100)
        };

        var swapTotal = node.systemStats.swap_total;
        var swapUsed = node.systemStats.swap_used;
        node.swapUsageConf = {
          exist: swapTotal > 0 && _.isFinite(swapUsed),
          height: swapUsed / swapTotal * 100,
          top: 105 - (swapUsed / swapTotal * 100),
          value: _.truncateTo3Digits((swapUsed / swapTotal) * 100)
        };

        var cpuRate = node.systemStats.cpu_utilization_rate;
        node.cpuUsageConf = {
          exist: _.isFinite(cpuRate),
          height: Math.floor(cpuRate * 100) / 100,
          top: 105 - (Math.floor(cpuRate * 100) / 100),
          value: _.truncateTo3Digits(Math.floor(cpuRate * 100) / 100)
        };

        return node;
      });
    }

    function prepareNodes(responses) {
      var groups = responses[1];
      var poolDefault = responses[0];
      var isGroupsAvailable = poolDefault.isGroupsAvailable && poolDefault.serverGroupsUri;
      var nodes = poolDefault.nodes;

      if (isGroupsAvailable) {
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

      _.each(mnAdminServersService.getPendingEject(), function (node) {
        var original = _.detect(nodes, function (n) {
          return n.otpNode == node.otpNode;
        });
        if (!original || original.clusterMembership === 'inactiveAdded') {
          return;
        }
        stillActualEject.push(original);
        original.pendingEject = true;
      });

      mnAdminServersService.setPendingEject(stillActualEject);

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
      }).concat(mnAdminServersService.getPendingEject());
      rv.reallyActive = _.filter(rv.onlyActive, function (node) {
        return !node.pendingEject
      });
      rv.unhealthyActive = _.detect(rv.reallyActive, function (node) {
        return node.status === 'unhealthy';
      });
      rv.ramTotalPerActiveNode = poolDefault.storageTotals.ram.total / rv.onlyActive.length;

      return rv;
    };

    mnAdminServersService.getNodes = function () {
      return $q.all([
        mnPoolDefault.getFresh(),
        mnAdminServersService.getGroups()
      ]).then(prepareNodes);
    };

    mnAdminServersService.getServersState = function (stateParamsNodeType) {
      return $q.all([
        mnAdminServersService.getNodes(),
        mnPoolDefault.get(),
        mnTasksDetails.get()
      ]).then(function (results) {

        var rv = {};
        var poolDefault = results[1];
        var nodes = results[0];
        var tasks = results[2];
        rv.allNodes = nodes.allNodes;
        rv.isGroupsAvailable = poolDefault.isGroupsAvailable;
        rv.currentNodes = prepareNode(nodes, tasks, stateParamsNodeType);
        rv.recommendedRefreshPeriod = tasks.recommendedRefreshPeriod;
        rv.rebalancing = poolDefault.rebalancing;
        rv.pendingLength = nodes.pending.length;
        rv.mayRebalanceWithoutSampleLoading = !poolDefault.rebalancing && !tasks.inRecoveryMode && (!!nodes.pending.length || !poolDefault.balanced) && !nodes.unhealthyActiveNodes;
        rv.mayRebalance = rv.mayRebalanceWithoutSampleLoading && !tasks.isLoadingSamples;
        rv.showWarningMessage = rv.mayRebalanceWithoutSampleLoading && tasks.isLoadingSamples;
        rv.showPendingBadge = !rv.rebalancing && rv.pendingLength;
        rv.failoverWarnings = _.map(poolDefault.failoverWarnings, function (failoverWarning) {
          switch (failoverWarning) {
            case 'failoverNeeded': return;
            case 'rebalanceNeeded': return 'Rebalance required, some data is not currently replicated!';
            case 'hardNodesNeeded': return 'At least two servers are required to provide replication!';
            case 'softNodesNeeded': return 'Additional active servers required to provide the desired number of replicas!';
            case 'softRebalanceNeeded': return 'Rebalance recommended, some data does not have the desired replicas configuration!';
          }
        });
        return rv;
      });
    };

    mnAdminServersService.addServer = function (selectedGroup, newServer) {
      return mnHttp({
        method: 'POST',
        url: (selectedGroup && selectedGroup.addNodeURI) || '/controller/addNode',
        data: newServer
      });
    };

    return mnAdminServersService;
  });
