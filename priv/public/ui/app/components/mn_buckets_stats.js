(function () {
  "use strict";

  angular
    .module("mnBucketsStats", [])
    .factory("mnBucketsStats", mnBucketsFactory);

  function mnBucketsFactory($http, $cacheFactory) {
    var mnBucketsStats = {
      get: get,
      clearCache: clearCache,
      getFresh: getFresh,
      isCached: isCached
    };

    return mnBucketsStats;

    function get(mnHttpParams) {
      return $http({
        method: "GET",
        cache: true,
        url: '/pools/default/buckets?basic_stats=true&skipMap=true',
        mnHttp: mnHttpParams
      });
    }

    function clearCache() {
      $cacheFactory.get('$http').remove('/pools/default/buckets?basic_stats=true&skipMap=true');
      return this;
    }

    function isCached() {
      return !!$cacheFactory.get('$http').get('/pools/default/buckets?basic_stats=true&skipMap=true');
    }

    function getFresh(mnHttpParams) {
      return mnBucketsStats.clearCache().get(mnHttpParams);
    }
  }
})();
