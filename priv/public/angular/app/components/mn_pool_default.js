angular.module('mnPoolDefault', [
  'mnHttp',
  'mnPools'
]).factory('mnPoolDefault',
  function (mnHttp, $cacheFactory, $q, mnPools, $window) {
    var mnPoolDefault = {};
    var latestValue;

    mnPoolDefault.latestValue = function () {
      return latestValue;
    };

    mnPoolDefault.get = function () {
      return $q.all([
        mnHttp({
          method: 'GET',
          url: '/pools/default?waitChange=0',
          responseType: 'json',
          cache: true,
          timeout: 30000
        }),
        mnPools.get()
      ]).then(function (resp) {
        var poolDefault = resp[0].data;
        var pools = resp[1]
        poolDefault.rebalancing = poolDefault.rebalanceStatus !== 'none';
        poolDefault.isGroupsAvailable = !!(pools.isEnterprise && poolDefault.serverGroupsUri);
        poolDefault.isEnterprise = pools.isEnterprise;
        poolDefault.isROAdminCreds = pools.isROAdminCreds;
        poolDefault.thisNode = _.detect(poolDefault.nodes, function (n) {
          return n.thisNode;
        });
        poolDefault.isKvNode =  _.indexOf(poolDefault.thisNode.services, "kv") > -1;
        poolDefault.capiBase = $window.location.protocol === "https:" ? poolDefault.thisNode.couchApiBaseHTTPS : poolDefault.thisNode.couchApiBase;
        latestValue = poolDefault;
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
