angular.module('mnAdminServersListItemDetailsService').factory('mnAdminServersListItemDetailsService',
  function (mnHttp, $q, mnTasksDetails) {
    var mnAdminServersListItemDetailsService = {};

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

    function prepareRebalanceDetails(detailedProgress) {
      var rv = {};
      if (detailedProgress) {
        rv.detailedProgress = {};

        var ingoing = detailedProgress.ingoing;
        if (ingoing.activeVBucketsLeft != 0 || ingoing.replicaVBucketsLeft != 0 || ingoing.docsTotal != 0 || ingoing.docsTransferred != 0) {
          rv.detailedProgress.ingoing = ingoing;
        } else {
          rv.detailedProgress.ingoing = false;
        }

        var outgoing = detailedProgress.outgoing;
        if (outgoing.activeVBucketsLeft != 0 || outgoing.replicaVBucketsLeft != 0 || outgoing.docsTotal != 0 || outgoing.docsTransferred != 0) {
          rv.detailedProgress.outgoing = outgoing;
        } else {
          rv.detailedProgress.outgoing = false;
        }

        rv.detailedProgress.bucket = detailedProgress.bucket;
        rv.detailedProgress.bucketNumber = detailedProgress.bucketNumber;
        rv.detailedProgress.bucketsCount = detailedProgress.bucketsCount;
      } else {
        rv.detailedProgress = false;
      }
      return rv;
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
        rv.detailedProgress = rebalanceTask.detailedProgress.perNode && rebalanceTask.detailedProgress.perNode[node.otpNode];

        rv.details = details;
        return rv;
      });
    };

    return mnAdminServersListItemDetailsService;
  });
