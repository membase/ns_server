angular.module('mnPoolDefault').factory('mnPoolDefault',
  function (mnHttp, $cacheFactory, $q) {
    var mnPoolDefault = {};

    mnPoolDefault.get = function () {
      return mnHttp({
        method: 'GET',
        url: '/pools/default?waitChange=0',
        responseType: 'json',
        cache: true,
        timeout: 30000
      }).then(function (resp) {
        var poolDefault = resp.data;
        poolDefault.rebalancing = poolDefault.rebalanceStatus !== 'none';
        poolDefault.isGroupsAvailable = !!(poolDefault.isEnterprise && poolDefault.serverGroupsUri);
        return poolDefault;
      });
    };

    mnPoolDefault.clearCache = function () {
      $cacheFactory.get('$http').remove('/pools/default?waitChange=0');
      return this;
    };

    mnPoolDefault.getFresh = function () {
      return mnPoolDefault.clearCache().get();
    };

    return mnPoolDefault;
  });
