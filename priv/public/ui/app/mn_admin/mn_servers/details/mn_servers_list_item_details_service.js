(function () {
  angular.module('mnServersListItemDetailsService', [
    'mnTasksDetails'
  ]).factory('mnServersListItemDetailsService', mnServersListItemDetailsFactory);

  function mnServersListItemDetailsFactory($http, $q, mnTasksDetails) {
    var mnServersListItemDetailsService = {
      getNodeDetails: getNodeDetails,
      getNodeTasks: getNodeTasks
    };

    return mnServersListItemDetailsService;

    function getBaseConfig(totals) {
      if (!totals) {
        return;
      }
      return {
        items: [{
          name: 'used',
          value: totals.usedByData
        },
        {
          name: 'remaining',
          value: totals.total - totals.used,
        }]
      };
    }

    function getNodeTasks(node, tasks) {
      if (!tasks || !node) {
        return;
      }
      var rebalanceTask = tasks.tasksRebalance.status === 'running' && tasks.tasksRebalance;
      return {
        warmUpTasks: _.filter(tasks.tasksWarmingUp, function (task) {
          return task.node === node.otpNode;
        }),
        detailedProgress: rebalanceTask.detailedProgress && rebalanceTask.detailedProgress.perNode && rebalanceTask.detailedProgress.perNode[node.otpNode]
      };
    }

    function getNodeDetails(node) {
      return $http({method: 'GET', url: '/nodes/' + encodeURIComponent(node.otpNode)}).then(function (resp) {
        var rv = {};
        var details = resp.data;
        var memoryCacheConfig = getBaseConfig(details.storageTotals.ram);

        if (!memoryCacheConfig) {
          return;
        }

        rv.getDiskStorageConfig = getBaseConfig(details.storageTotals.hdd);
        rv.getMemoryCacheConfig = memoryCacheConfig;
        rv.details = details;
        return rv;
      });
    }
  }
})();
