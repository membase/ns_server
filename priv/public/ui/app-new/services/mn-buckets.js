var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnBuckets = (function () {
  "use strict";

  MnBucketsService.annotations = [
    new ng.core.Injectable()
  ];

  MnBucketsService.parameters = [
    ng.common.http.HttpClient
  ];

  MnBucketsService.prototype.get = get;

  return MnBucketsService;

  function MnBucketsService(http) {
    this.http = http;
    this.stream = {};
    this.stream.getSuccess = this.get().share();
  }

  function get() {
    return this.http
      .get('/pools/default/buckets?basic_stats=true&skipMap=true')
      .map(function (bucketsDetails) {
        bucketsDetails.byType = {membase: [], memcached: [], ephemeral: []};
        bucketsDetails.byType.membase.isMembase = true;
        bucketsDetails.byType.memcached.isMemcached = true;
        bucketsDetails.byType.ephemeral.isEphemeral = true;
        bucketsDetails.byType.names = _.pluck(bucketsDetails, 'name');

        bucketsDetails.byName = {};
        bucketsDetails.forEach(function (bucket) {
          bucketsDetails.byName[bucket.name] = bucket;
          bucketsDetails.byType[bucket.bucketType].push(bucket);
          bucket.isMembase = bucket.bucketType === 'membase';
          bucket.isEphemeral = bucket.bucketType === 'ephemeral';
          bucket.isMemcached = bucket.bucketType === 'memcached';
        });

        return bucketsDetails;
      });
  }

})();
