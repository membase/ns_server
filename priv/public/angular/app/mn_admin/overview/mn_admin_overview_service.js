angular.module('mnAdminOverviewService').factory('mnAdminOverviewService',
  function ($rootScope, mnAdminService, $http, $timeout) {
    var mnAdminOverviewService = {};

    mnAdminOverviewService.model = {};

    var statsLoopTimeout;

    function runStatsLoop(stats) {
      if (!stats) {
        return;
      }
      mnAdminOverviewService.model.stats = stats;

      var ts = stats.timestamp;
      var interval = ts[ts.length - 1] - ts[0];
      if (isNaN(interval) || interval < 15000) {
        statsLoopTimeout = $timeout(mnAdminOverviewService.runStatsLoop, 15000);
      } else if (interval < 300000) {
        statsLoopTimeout = $timeout(mnAdminOverviewService.runStatsLoop, 10000);
      } else {
        statsLoopTimeout = $timeout(mnAdminOverviewService.runStatsLoop, 30000);
      }
    }

    mnAdminOverviewService.stopStatsLoop = function () {
      $timeout.cancel(statsLoopTimeout);
    };

    mnAdminOverviewService.runStatsLoop = function () {
      $http({url: '/pools/default/overviewStats', method: "GET"}).success(runStatsLoop);
    };

    // function filterActiveNodes(node) {
    //   return node.clusterMembership === 'active' || node.clusterMembership === 'inactiveFailed';
    // }

    // function filterPendingNodes(node) {
    //   return node.clusterMembership !== 'active';
    // }

    // function filterFailedOverNodes(node) {
    //   return node.clusterMembership === 'inactiveFailed';
    // }

    // function filterDownNodes(node) {
    //   return node.status !== 'healthy';
    // }

    // mnAdminService.$watch('details.nodes', function (allNodes) {
    //   if (!allNodes) {
    //     return;
    //   }

    //   $scope.model.pendingNodesLength = _.filter(allNodes, filterPendingNodes).length;
    //   $scope.model.activeNodesLength = _.filter(allNodes, filterActiveNodes).length;
    //   $scope.model.failedOverNodesLength = _.filter(allNodes, filterFailedOverNodes).length;
    //   $scope.model.downNodesLength = _.filter(allNodes, filterDownNodes).length;
    // });

    return mnAdminOverviewService;
  });
