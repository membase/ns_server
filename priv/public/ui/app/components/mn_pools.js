(function () {
  "use strict";

  angular.module('mnPools', [
    'mnHttp'
  ]).factory('mnPools', mnPoolsFactory);

  function mnPoolsFactory(mnHttp, $cacheFactory) {
    var mnPools = {
      isEnterprise: isEnterprise,
      get: get,
      clearCache: clearCache,
      getFresh: getFresh
    };

    var launchID =  (new Date()).valueOf() + '-' + ((Math.random() * 65536) >> 0);

    return mnPools;

    function isEnterprise() {
      return mnPools.value && mnPools.value.isEnterprise;
    }
    function get() {
      return mnHttp({
        method: 'GET',
        url: '/pools',
        cache: true,
        requestType: 'json'
      }).then(function (resp) {
        var pools = resp.data;
        var rv = {};
        pools.isInitialized = !!pools.pools.length;
        pools.isAuthenticated = pools.isAdminCreds && pools.isInitialized;
        pools.launchID = pools.uuid + '-' + launchID;
        mnPools.value = pools;
        return pools;
      }, function (resp) {
        if (resp.status === 401) {
          return {isInitialized: true, isAuthenticated: false};
        }
      });
    }
    function clearCache() {
      $cacheFactory.get('$http').remove('/pools');
      return this;
    }
    function getFresh() {
      return mnPools.clearCache().get();
    }
  }
})();
