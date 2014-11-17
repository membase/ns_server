angular.module('mnAdminServersListItemDetailsService').factory('mnAdminServersListItemDetailsService',
  function (mnHttp, $q, mnTasksDetails) {
    var mnAdminServersListItemDetailsService = {};

    function formatWarmupMessages(warmupTasks, keyName) {
      if (!warmupTasks.length) {
        return false;
      }
      warmupTasks = _.sortBy(_.clone(warmupTasks), keyName);
      var originLength = warmupTasks.length;
      if (warmupTasks.length > 3) {
        warmupTasks.length = 3;
      }

      var rv = _.map(warmupTasks, function (task) {
        var message = task.stats.ep_warmup_state;

        switch (message) {
          case "loading keys":
            message += " (" + task.stats.ep_warmup_key_count +
              " / " + task.stats.ep_warmup_estimated_key_count + ")";
          break;
          case "loading data":
            message += " (" + task.stats.ep_warmup_value_count +
              " / " + task.stats.ep_warmup_estimated_value_count + ")";
          break;
        }
        return {key: task[keyName], status: message};
      });

      if (warmupTasks.length === 3 && originLength > 3) {
        rv.push({key: "more ...", status: ""});
      }

      return rv;
    }

    function getBaseConfig(totals) {
      return {
        topRight: {
          name: 'Total',
          value: _.formatMemSize(totals.total)
        },
        items: [{
          name: 'In Use',
          value: totals.usedByData,
          itemStyle: {'background-color': '#00BCE9'},
          labelStyle: {'color': '#1878A2', 'text-align': 'left'}
        }, {
          name: 'Other Data',
          value: totals.used - totals.usedByData,
          itemStyle: {"background-color": "#FDC90D"},
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

    mnAdminServersListItemDetailsService.getNodeDetails = function (node) {
      return $q.all([
        mnHttp({method: 'GET', url: '/nodes/' + encodeURIComponent(node.otpNode)}),
        mnTasksDetails.get()
      ]).then(function (resp) {
        var rv = {};
        var details = resp[0].data;
        var tasks = resp[1];
        rv.getDiskStorageConfig = getBaseConfig(details.storageTotals.hdd);

        var memoryCacheConfig = getBaseConfig(details.storageTotals.ram);
        memoryCacheConfig.topLeft = {
          name: 'Couchbase Quota',
          value: _.formatMemSize(details.storageTotals.ram.quotaTotal)
        };

        memoryCacheConfig.markers.push({
          track: 1,
          value: details.storageTotals.ram.quotaTotal,
          itemStyle: {"background-color": "#E43A1B"}
        });

        rv.getMemoryCacheConfig = memoryCacheConfig;
        rv.uptime = _.formatUptime(details.uptime);
        rv.ellipsisPath = details.storage.hdd[0] && _.ellipsisiseOnLeft(details.storage.hdd[0].path || "", 25);

        var rebalanceTask = tasks.tasksRebalance.status === 'running' && tasks.tasksRebalance;
        rv.detailedProgress = rebalanceTask.detailedProgress && rebalanceTask.detailedProgress.perNode && rebalanceTask.detailedProgress.perNode[node.otpNode];

        rv.warmUpTasks = formatWarmupMessages(_.filter(tasks.tasksWarmingUp, function (task) {
          return task.node === node.otpNode;
        }), 'bucket');

        rv.details = details;
        return rv;
      });
    };

    return mnAdminServersListItemDetailsService;
  });
