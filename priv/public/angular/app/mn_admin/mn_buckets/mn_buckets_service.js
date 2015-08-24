angular.module('mnBucketsService', [
  'mnHttp',
  'mnPoolDefault',
  'mnFilters'
]).factory('mnBucketsService',
  function (mnHttp, $q, mnPoolDefault, mnTruncateTo3DigitsFilter, mnCalculatePercentFilter) {
    var mnBucketsService = {};

    mnBucketsService.model = {};

    mnBucketsService.getBucketsState = function () {
      return $q.all([
        mnPoolDefault.getFresh(),
        mnBucketsService.getBucketsByType()
      ]).then(function (resp) {
        var poolsDefault = resp[0];
        var bucketsDetails = resp[1];

        _.each(bucketsDetails, function (bucket) {
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

        var warnings = [];
        var totals = poolsDefault.storageTotals;
        if (poolsDefault.rebalancing) {
          warnings.push('Cannot create buckets while rebalance is running.');
        }
        if (totals.ram.quotaTotal == totals.ram.quotaUsed) {
          warnings.push('Cluster memory fully allocated. Delete some buckets or change bucket sizes to make RAM available for additional buckets.');
        }
        if (bucketsDetails.length >= poolsDefault.maxBucketCount) {
          warnings.push('Maximum number of buckets has been reached.\n\nFor optimal performance, no more than ' + poolsDefault.maxBucketCount + ' buckets are allowed.');
        }

        bucketsDetails.creationWarnings = warnings;

        return bucketsDetails;
      })
    };

    mnBucketsService.getBucketsByType = function () {
      return mnHttp.get('/pools/default/buckets?basic_stats=true').then(function (resp) {
        var bucketsDetails = resp.data
        bucketsDetails.byType = {membase: [], memcached: []};
        bucketsDetails.byType.membase.isMembase = true;
        bucketsDetails.byType.memcached.isMemcached = true;
        _.each(bucketsDetails, function (bucket) {
          bucketsDetails.byType[bucket.bucketType].push(bucket);
          bucket.isMembase = bucket.bucketType === 'membase';
        });
        bucketsDetails.byType.membase.names = _.pluck(bucketsDetails.byType.membase, 'name');
        bucketsDetails.byType.membase.defaultName = _.contains(bucketsDetails.byType.membase.names, 'default') ? 'default' : bucketsDetails.byType.membase.names[0] || '';
        return bucketsDetails;
      });
    };

    return mnBucketsService;
  });
