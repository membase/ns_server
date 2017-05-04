(function () {
  angular.module('mnBucketsService', [
    'mnBucketsStats'
  ]).factory('mnBucketsService', mnBucketsServiceFactory);

  function mnBucketsServiceFactory($http, $q, mnBucketsStats) {
    var mnBucketsService = {
      getBucketsByType: getBucketsByType,
      export: {}
    };

    return mnBucketsService;

    function getBucketsByType(mnHttpParams) {
      if (mnBucketsStats.isCached()) {
        return $q.when(mnBucketsService.export.details);
      }
      return mnBucketsStats.get(mnHttpParams).then(function (resp) {
        var bucketsDetails = resp.data;
        bucketsDetails.byType = {membase: [], memcached: [], ephemeral: []};
        bucketsDetails.byName = {};
        bucketsDetails.byType.membase.isMembase = true;
        bucketsDetails.byType.memcached.isMemcached = true;
        bucketsDetails.byType.ephemeral.isEphemeral = true;
        _.each(bucketsDetails, function (bucket) {
          bucketsDetails.byName[bucket.name] = bucket;
          bucketsDetails.byType[bucket.bucketType].push(bucket);
          bucket.isMembase = bucket.bucketType === 'membase';
          bucket.isEphemeral = bucket.bucketType === 'ephemeral';
          bucket.isMemcached = bucket.bucketType === 'memcached';
        });
        bucketsDetails.byType.names = _.pluck(bucketsDetails, 'name');
        bucketsDetails.byType.defaultName = _.contains(bucketsDetails.byType.names, 'default') ? 'default' : bucketsDetails.byType.names[0] || '';

        bucketsDetails.byType.membase.names = _.pluck(bucketsDetails.byType.membase, 'name');
        bucketsDetails.byType.membase.defaultName = _.contains(bucketsDetails.byType.membase.names, 'default') ? 'default' : bucketsDetails.byType.membase.names[0] || '';

        bucketsDetails.byType.ephemeral.names = _.pluck(bucketsDetails.byType.ephemeral, 'name');
        bucketsDetails.byType.ephemeral.defaultName = _.contains(bucketsDetails.byType.ephemeral.names, 'default') ? 'default' : bucketsDetails.byType.ephemeral.names[0] || '';

        mnBucketsService.export.details = bucketsDetails;
        return bucketsDetails;
      });
    }
  }
})();
