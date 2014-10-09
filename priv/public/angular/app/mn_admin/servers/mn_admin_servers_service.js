angular.module('mnAdminServersService').factory('mnAdminServersService',
  function ($http, $q, mnAdminService, mnAdminServersListItemService) {
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

    return mnAdminServersService;
  });
