var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnPools = (function () {
  "use strict";

  var launchID =  (new Date()).valueOf() + '-' + ((Math.random() * 65536) >> 0);

  var MnPools =
      ng.core.Injectable()
      .Class({
        constructor: [
          ng.common.http.HttpClient,
          function MnPoolsService(http) {
            this.http = http;
            this.get$ = this.get();
          }],
        get: get,
      });

  return MnPools;

  function get(mnHttpParams) {
    return this.http
      .get('/pools').map(function (pools) {
        pools.isInitialized = !!pools.pools.length;
        pools.launchID = pools.uuid + '-' + launchID;
        return pools;
      }).catch(function (resp) {
        return Rx.Observable.of(resp);
      });
  }
})();
