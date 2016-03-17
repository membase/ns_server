(function () {
  angular.module('mnBucketsDetailsService', [
    'mnPoolDefault',
    'mnTasksDetails',
    'mnCompaction'
  ]).factory('mnBucketsDetailsService', mnBucketsDetailsServiceFcatory);

  function mnBucketsDetailsServiceFcatory($q, $http, mnTasksDetails, mnPoolDefault, mnCompaction) {
    var mnBucketsDetailsService = {
      getBucketRamGuageConfig: getBucketRamGuageConfig,
      deleteBucket: deleteBucket,
      flushBucket: flushBucket,
      doGetDetails: doGetDetails,
      getWarmUpTasks: getWarmUpTasks,
      getGuageConfig: getGuageConfig,
      getCompactionTask: getCompactionTask
    };

    var bucketRamGuageConfig = {};
    var guageConfig = {};

    return mnBucketsDetailsService;

    function getWarmUpTasks(bucket) {
      return $q.all([
        mnTasksDetails.get(),
        mnPoolDefault.getFresh()
      ]).then(function (resp) {
        var tasks = resp[0];
        var poolDefault = resp[0];

        return _.filter(tasks.tasks, function (task) {
          var isNeeded = task.type === 'warming_up' && task.status === 'running' && task.bucket === bucket.name;
          if (isNeeded) {
            task.hostname = _.find(poolDefault.nodes, function (node) {
              return node.otpNode === task.node;
            }).hostname;
          }
          return isNeeded;
        });
      });
    }

    function getCompactionTask(bucket) {
      return mnTasksDetails.get().then(function (tasks) {
        var rv = {};
        rv.thisBucketCompactionTask = _.find(tasks.tasks, function (task) {
          return task.type === 'bucket_compaction' && task.bucket === bucket.name;
        });
        if (rv.thisBucketCompactionTask && !!rv.thisBucketCompactionTask.cancelURI) {
          rv.disableCancel = !!mnCompaction.getStartedCompactions()[rv.thisBucketCompactionTask.cancelURI];
        } else {
          rv.disableCompact = !!(mnCompaction.getStartedCompactions()[bucket.controllers.compactAll] || rv.thisBucketCompactionTask);
        }
        return rv
      });
    }

    function getBucketRamGuageConfig(ramSummary) {
      if (!ramSummary) {
        return;
      }
      bucketRamGuageConfig.topRight = {
        name: 'Cluster quota',
        value: ramSummary.total
      };
      bucketRamGuageConfig.items = [{
        name: 'Other Buckets',
        value: ramSummary.otherBuckets,
        itemStyle: {'background-color': '#00BCE9', 'z-index': '2'},
        labelStyle: {'color': '#1878a2', 'text-align': 'left'}
      }, {
        name: 'This Bucket',
        value: ramSummary.thisAlloc,
        itemStyle: {'background-color': '#7EDB49', 'z-index': '1'},
        labelStyle: {'color': '#409f05', 'text-align': 'center'}
      }, {
        name: 'Free',
        value: ramSummary.total - ramSummary.otherBuckets - ramSummary.thisAlloc,
        itemStyle: {'background-color': '#E1E2E3'},
        labelStyle: {'color': '#444245', 'text-align': 'right'}
      }];
      bucketRamGuageConfig.markers = [];

      if (bucketRamGuageConfig.items[2].value < 0) {
        bucketRamGuageConfig.items[1].value = ramSummary.total - ramSummary.otherBuckets;
        bucketRamGuageConfig.items[2] = {
          name: 'Overcommitted',
          value: ramSummary.otherBuckets + ramSummary.thisAlloc - ramSummary.total,
          itemStyle: {'background-color': '#F40015'},
          labelStyle: {'color': '#e43a1b'}
        };
        bucketRamGuageConfig.markers.push({
          value: ramSummary.total,
          itemStyle: {'background-color': '#444245'}
        });
        bucketRamGuageConfig.markers.push({
          value: ramSummary.otherBuckets + ramSummary.thisAlloc,
          itemStyle: {'background-color': 'red'}
        });
        bucketRamGuageConfig.topLeft = {
          name: 'Total Allocated',
          value: ramSummary.otherBuckets + ramSummary.thisAlloc,
          itemStyle: {'color': '#e43a1b'}
        };
      }
      return bucketRamGuageConfig;
    }

    function getGuageConfig(total, thisBucket, otherBuckets, otherData) {
      var free = total - otherData - thisBucket - otherBuckets;

      guageConfig.topLeft = {
        name: 'Other Data',
        value: otherData
      };
      guageConfig.topRight = {
        name: 'Total Cluster Storage',
        value: total
      };
      guageConfig.items = [{
        name: null,
        value: otherData,
        itemStyle: {'background-color':'#FDC90D', 'z-index': '3'},
        labelStyle: {}
      }, {
        name: 'Other Buckets',
        value: otherBuckets,
        itemStyle: {'background-color':'#00BCE9', 'z-index': '2'},
        labelStyle: {'color':'#1878a2', 'text-align': 'left'}
      }, {
        name: 'This Bucket',
        value: thisBucket,
        itemStyle: {'background-color':'#7EDB49', 'z-index': '1'},
        labelStyle: {'color':'#409f05', 'text-align': 'center'}
      }, {
        name: 'Free',
        value: free,
        itemStyle: {'background-color':'#E1E2E3'},
        labelStyle: {'color':'#444245', 'text-align': 'right'}
      }];

      return guageConfig;
    }

    function deleteBucket(bucket) {
      return $http({
        method: 'DELETE',
        url: bucket.uri
      });
    }
    function flushBucket(bucket) {
      return $http({
        method: 'POST',
        url: bucket.controllers.flush
      });
    }
    function doGetDetails(bucket) {
      return $http({
        method: 'GET',
        url: bucket.uri + "&basic_stats=true&skipMap=true"
      }).then(function (resp) {
        return resp.data;
      });
    }
  }
})();
