(function () {
  "use strict";

  angular
    .module("mnBucketsStats", [])
    .factory("mnBucketsStats", mnBucketsFactory);

  function mnBucketsFactory($http, $cacheFactory) {
    var mnBucketsStats = {
      get: get,
      clearCache: clearCache,
      getFresh: getFresh
    };

    return mnBucketsStats;

    function get(mnHttpParams) {
      return $http({
        method: "GET",
        url: '/pools/default/buckets?basic_stats=true',
        mnHttp: mnHttpParams
      });
    }

    function clearCache() {
      $cacheFactory.get('$http').remove('/pools/default/buckets?basic_stats=true');
      return this;
    }

    function getFresh(mnHttpParams) {
      return mnBucketsStats.clearCache().get(mnHttpParams);
    }
  }
})();
