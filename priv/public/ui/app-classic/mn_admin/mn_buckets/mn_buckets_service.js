(function () {
  angular.module('mnBucketsService', [
    'mnBucketsStats'
  ]).factory('mnBucketsService', mnBucketsServiceFactory);

  function mnBucketsServiceFactory($http, $q, mnBucketsStats) {
    var mnBucketsService = {
      getBucketsByType: getBucketsByType,
      getBucketsForBucketsPage: getBucketsForBucketsPage
    };

    return mnBucketsService;

    function getPieConfig(bucket) {
      var h = _.reduce(_.pluck(bucket.nodes, 'status'), function (counts, stat) {
        counts[stat] = (counts[stat] || 0) + 1;
        return counts;
      }, {});

      var pieConfig = {};
      var healthStats = [h.healthy || 0, h.warmup || 0, h.unhealthy || 0];
      pieConfig.status = _.clone(healthStats);

      var total = _.inject(healthStats, function (a,b) {return a+b}, 0);

      var minimalAngle = Math.PI/180*30;
      var nodeSize = total < 1E-6 ? 0 : Math.PI*2/total;

      var stolenSize = 0;
      var maxAngle = 0;
      var maxIndex = -1;

      for (var i = healthStats.length; i--;) {
        var newValue = healthStats[i] * nodeSize;
        if (newValue != 0 && newValue < minimalAngle) {
          stolenSize += minimalAngle - newValue;
          newValue = minimalAngle;
        }
        healthStats[i] = newValue;
        if (newValue >= maxAngle) {
          maxAngle = newValue;
          maxIndex = i;
        }
      }

      pieConfig.series = healthStats;
      bucket.pieConfig = pieConfig;
    }

    function getBucketsForBucketsPage(fromCache, mnHttpParams) {
      return getBucketsByType(fromCache, mnHttpParams).then(function (buckets) {
        angular.forEach(buckets, getPieConfig);
        return buckets;
      });
    }

    function getBucketsByType(fromCache, mnHttpParams) {
      return mnBucketsStats[fromCache ? "get" : "getFresh"](mnHttpParams).then(function (resp) {
        var bucketsDetails = resp.data
        bucketsDetails.byType = {membase: [], memcached: [], ephemeral: []};
        bucketsDetails.byType.membase.isMembase = true;
        bucketsDetails.byType.memcached.isMemcached = true;
        _.each(bucketsDetails, function (bucket) {
          bucketsDetails.byType[bucket.bucketType].push(bucket);
          bucket.isMembase = bucket.bucketType === 'membase';
        });
        bucketsDetails.byType.names = _.pluck(bucketsDetails, 'name');
        bucketsDetails.byType.defaultName = _.contains(bucketsDetails.byType.names, 'default') ? 'default' : bucketsDetails.byType.names[0] || '';
        bucketsDetails.byType.membase.names = _.pluck(bucketsDetails.byType.membase, 'name');
        bucketsDetails.byType.membase.defaultName = _.contains(bucketsDetails.byType.membase.names, 'default') ? 'default' : bucketsDetails.byType.membase.names[0] || '';
        return bucketsDetails;
      });
    }
  }
})();
