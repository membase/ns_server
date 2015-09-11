(function () {
  "use strict";

  angular
    .module("mnBucketsStats", ["mnHttp"])
    .factory("mnBucketsStats", mnBucketsFactory);

  function mnBucketsFactory(mnHttp, $cacheFactory) {
    var mnBucketsStats = {
      get: get,
      clearCache: clearCache,
      getFresh: getFresh
    };

    return mnBucketsStats;

    function get() {
      return mnHttp.get('/pools/default/buckets?basic_stats=true');
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
