angular.module('mnPools', [
  'mnHttp'
]).factory('mnPools',
  function (mnHttp, $cacheFactory) {
    var mnPools = {};

    var launchID =  (new Date()).valueOf() + '-' + ((Math.random() * 65536) >> 0);

    mnPools.get = function () {
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
        return pools;
      }, function (resp) {
        if (resp.status === 401) {
          return {isInitialized: true, isAuthenticated: false};
        }
      });
    };


    mnPools.clearCache = function () {
      $cacheFactory.get('$http').remove('/pools');
      return this;
    };

    mnPools.getFresh = function () {
      return mnPools.clearCache().get();
    };

    return mnPools;
  });
