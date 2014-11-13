angular.module('mnPools').factory('mnPools',
  function (mnHttp, $cacheFactory) {
    var mnPools = {};

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
