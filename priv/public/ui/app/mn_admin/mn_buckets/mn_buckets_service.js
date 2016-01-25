(function () {
  angular.module('mnBucketsService', [
    'mnBucketsStats'
  ]).factory('mnBucketsService', mnBucketsServiceFactory);

  function mnBucketsServiceFactory($http, $q, mnBucketsStats) {
    var mnBucketsService = {
      getBucketsByType: getBucketsByType
    };

    return mnBucketsService;

    function getBucketsByType(fromCache, mnHttpParams) {
      return mnBucketsStats[fromCache ? "get" : "getFresh"](mnHttpParams).then(function (resp) {
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
    }
  }
})();
