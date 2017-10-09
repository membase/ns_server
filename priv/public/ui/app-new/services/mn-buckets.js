var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnBuckets = (function () {
  "use strict";

  var MnBuckets =
      ng.core.Injectable()
      .Class({
        constructor: [
          ng.common.http.HttpClient,
          function MnBucketsService(http) {
            this.http = http;
            this.stream = {};
            this.stream.getSuccess = this.get().share();
          }],
        get: get,
      });

  return MnBuckets;

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
