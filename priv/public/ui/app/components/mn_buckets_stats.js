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

    function get() {
      return $http.get('/pools/default/buckets?basic_stats=true');
    }

    function clearCache() {
      $cacheFactory.get('$http').remove('/pools/default/buckets?basic_stats=true');
      return this;
    }

    function getFresh() {
      return mnBucketsStats.clearCache().get();
    }
  }
})();
