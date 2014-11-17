angular.module('mnBucketsService').factory('mnBucketsService',
  function (mnHttp) {
    var mnBucketsService = {};

    mnBucketsService.model = {};

    mnBucketsService.getRawDetailedBuckets = function () {
      return mnHttp.get('/pools/default/buckets?basic_stats=true').success(populateModel);
    };

    function populateModel(bucketsDetails) {
      // adding a child object for storing bucket by their type
      bucketsDetails.byType = {"membase":[], "memcached":[]};

      _.each(bucketsDetails, function (bucket) {
        var storageTotals = bucket.basicStats.storageTotals;

        if (bucket.bucketType == 'memcached') {
          bucket.bucketTypeName = 'Memcached';
        } else if (bucket.bucketType == 'membase') {
          bucket.bucketTypeName = 'Couchbase';
        } else {
          bucket.bucketTypeName = bucket.bucketType;
        }
        if (bucketsDetails.byType[bucket.bucketType] === undefined) {
          bucketsDetails.byType[bucket.bucketType] = [];
        }
        bucketsDetails.byType[bucket.bucketType].push(bucket);

        bucket.ramQuota = bucket.quota.ram;
        bucket.totalRAMSize = storageTotals.ram.total;
        bucket.totalRAMUsed = bucket.basicStats.memUsed;
        bucket.otherRAMSize = storageTotals.ram.used - bucket.totalRAMUsed;
        bucket.totalRAMFree = storageTotals.ram.total - storageTotals.ram.used;

        bucket.RAMUsedPercent = _.calculatePercent(bucket.totalRAMUsed, bucket.totalRAMSize);
        bucket.RAMOtherPercent = _.calculatePercent(bucket.totalRAMUsed + bucket.otherRAMSize, bucket.totalRAMSize);

        bucket.totalDiskSize = storageTotals.hdd.total;
        bucket.totalDiskUsed = bucket.basicStats.diskUsed;
        bucket.otherDiskSize = storageTotals.hdd.used - bucket.totalDiskUsed;
        bucket.totalDiskFree = storageTotals.hdd.total - storageTotals.hdd.used;

        bucket.diskUsedPercent = _.calculatePercent(bucket.totalDiskUsed, bucket.totalDiskSize);
        bucket.diskOtherPercent = _.calculatePercent(bucket.otherDiskSize + bucket.totalDiskUsed, bucket.totalDiskSize);
        function reduceFn(counts, stat) {
           counts[stat] = (counts[stat] || 0) + 1;
           return counts;
         }
        var h = _.reduce(_.pluck(bucket.nodes, 'status'), reduceFn, {});
        // order of these values is important to match pie chart colors
        bucket.healthStats = [h.healthy || 0, h.warmup || 0, h.unhealthy || 0];
      });

      mnBucketsService.model.bucketsDetails = bucketsDetails;
    }

    return mnBucketsService;
  });
