angular.module('mnPoolDetails').factory('mnPoolDetails',
  function (mnHttp, $cacheFactory) {
    var mnPoolDetails = {};

    mnPoolDetails.get = function () {
      return mnHttp({
        method: 'GET',
        url: '/pools/default?waitChange=0',
        responseType: 'json',
        cache: true,
        timeout: 30000
      }).then(function (resp) {
        var poolDetails = resp.data;
        poolDetails.rebalancing = poolDetails.rebalanceStatus !== 'none';
        poolDetails.isGroupsAvailable = !!(poolDetails.isEnterprise && poolDetails.serverGroupsUri);
        return poolDetails;
      });
    };

    mnPoolDetails.clearCache = function () {
      $cacheFactory.get('$http').remove('/pools/default?waitChange=0');
      return this;
    };

    mnPoolDetails.getFresh = function () {
      return mnPoolDetails.clearCache().get();
    };

    return mnPoolDetails;
  });
