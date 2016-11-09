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
      return {
        topRight: {
          name: 'Total',
          value: totals.total
        },
        items: [{
          name: 'In Use by Buckets',
          value: totals.usedByData,
          itemStyle: {'background-color': '#00BCE9', 'z-index': 3},
          labelStyle: {'color': '#1878A2', 'text-align': 'left'}
        }, {
          name: 'Other Data',
          value: totals.used - totals.usedByData,
          itemStyle: {"background-color": "#FDC90D", 'z-index': 2},
          labelStyle: {"color": "#C19710",  'text-align': 'center'}
        }, {
          name: 'Free',
          value: totals.total - totals.used,
          itemStyle: {},
          labelStyle: {'text-align': 'right'}
        }],
        markers: []
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

        memoryCacheConfig.topLeft = {
          name: 'Couchbase Quota',
          value: details.storageTotals.ram.quotaTotal
        };

        memoryCacheConfig.markers.push({
          track: 1,
          value: details.storageTotals.ram.quotaTotal,
          itemStyle: {"background-color": "#E43A1B"}
        });

        rv.getDiskStorageConfig = getBaseConfig(details.storageTotals.hdd);
        rv.getMemoryCacheConfig = memoryCacheConfig;
        rv.details = details;
        return rv;
      });
    }
  }
})();