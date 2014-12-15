angular.module('mnBucketsService').factory('mnBucketsService',
  function (mnHttp, mnTruncateTo3DigitsFilter, mnCalculatePercentFilter) {
    var mnBucketsService = {};

    mnBucketsService.model = {};

    mnBucketsService.getBuckets = function () {
      return mnHttp.get('/pools/default/buckets?basic_stats=true').then(function (resp) {
        var bucketsDetails = resp.data;
        bucketsDetails.byType = {membase: [], memcached: []};
        bucketsDetails.byType.membase.isMembase = true;
        bucketsDetails.byType.memcached.isMemcached = true;

        _.each(bucketsDetails, function (bucket) {
          bucketsDetails.byType[bucket.bucketType].push(bucket);
          bucket.isMembase = bucket.bucketType === 'membase';

          if (bucket.isMembase) {
            bucket.truncatedDiskFetches = mnTruncateTo3DigitsFilter(bucket.basicStats.diskFetches);
          } else {
            bucket.truncatedHitRatio = mnTruncateTo3DigitsFilter(bucket.basicStats.hitRatio * 100);
          }

          var storageTotals = bucket.basicStats.storageTotals;
          bucket.roundedOpsPerSec =  Math.round(bucket.basicStats.opsPerSec);

          bucket.ramQuota = bucket.quota.ram;
          bucket.totalRAMSize = storageTotals.ram.total;
          bucket.totalRAMUsed = bucket.basicStats.memUsed;
          bucket.otherRAMSize = storageTotals.ram.used - bucket.totalRAMUsed;
          bucket.totalRAMFree = storageTotals.ram.total - storageTotals.ram.used;
          bucket.RAMUsedPercent = mnCalculatePercentFilter(bucket.totalRAMUsed, bucket.totalRAMSize);
          bucket.RAMOtherPercent = mnCalculatePercentFilter(bucket.totalRAMUsed + bucket.otherRAMSize, bucket.totalRAMSize);
          bucket.totalDiskSize = storageTotals.hdd.total;
          bucket.totalDiskUsed = bucket.basicStats.diskUsed;
          bucket.otherDiskSize = storageTotals.hdd.used - bucket.totalDiskUsed;
          bucket.totalDiskFree = storageTotals.hdd.total - storageTotals.hdd.used;
          bucket.diskUsedPercent = mnCalculatePercentFilter(bucket.totalDiskUsed, bucket.totalDiskSize);
          bucket.diskOtherPercent = mnCalculatePercentFilter(bucket.otherDiskSize + bucket.totalDiskUsed, bucket.totalDiskSize);
          function reduceFn(counts, stat) {
            counts[stat] = (counts[stat] || 0) + 1;
            return counts;
          }
          var h = _.reduce(_.pluck(bucket.nodes, 'status'), reduceFn, {});
          // order of these values is important to match pie chart colors
          bucket.healthStats = [h.healthy || 0, h.warmup || 0, h.unhealthy || 0];
        });

        return bucketsDetails;
      });
    };

    return mnBucketsService;
  });
