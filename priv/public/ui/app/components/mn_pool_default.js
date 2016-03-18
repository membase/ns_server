(function () {
  "use strict";

  angular
    .module('mnPoolDefault', [
      'mnPools'
    ])
    .factory('mnPoolDefault', mnPoolDefaultFactory);

  function mnPoolDefaultFactory($http, $q, mnPools, $window) {
    var latest = {};
    var mnPoolDefault = {
      latestValue: latestValue,
      get: get,
      clearCache: clearCache,
      getFresh: getFresh,
      export: {
        compat: undefined
      }
    };
    var version25 = encodeCompatVersion(2, 5);
    var version30 = encodeCompatVersion(3, 0);
    var version40 = encodeCompatVersion(4, 0);
    var version45 = encodeCompatVersion(4, 5);
    var cache;

    return mnPoolDefault;

    function latestValue() {
      return latest;
    }
    // counterpart of ns_heart:effective_cluster_compat_version/0
    function encodeCompatVersion(major, minor) {
      if (major < 2) {
        return 1;
      }
      return major * 0x10000 + minor;
    }
    function get(params, mnHttpParams) {
      if (!(params && params.etag) && cache) {
        return $q.when(cache);
      }
      params = params || {waitChange: 0};
      return $q.all([
        $http({
          mnHttp: mnHttpParams,
          method: 'GET',
          url: '/pools/default',
          responseType: 'json',
          params: params,
          timeout: 30000
        }),
        mnPools.get(mnHttpParams)
      ]).then(function (resp) {
        var poolDefault = resp[0].data;
        var pools = resp[1]
        poolDefault.rebalancing = poolDefault.rebalanceStatus !== 'none';
        //TODO replace serverGroupsUri in isGroupsAvailable using mixed cluster version
        poolDefault.isGroupsAvailable = !!(pools.isEnterprise && poolDefault.serverGroupsUri);
        poolDefault.isEnterprise = pools.isEnterprise;
        poolDefault.thisNode = _.detect(poolDefault.nodes, function (n) {
          return n.thisNode;
        });
        mnPoolDefault.export.compat = {
          atLeast25: poolDefault.thisNode.clusterCompatibility >= version25,
          atLeast30: poolDefault.thisNode.clusterCompatibility >= version30,
          atLeast40: poolDefault.thisNode.clusterCompatibility >= version40,
          atLeast45: poolDefault.thisNode.clusterCompatibility >= version45
        };

        poolDefault.isKvNode =  _.indexOf(poolDefault.thisNode.services, "kv") > -1;
        poolDefault.capiBase = $window.location.protocol === "https:" ? poolDefault.thisNode.couchApiBaseHTTPS : poolDefault.thisNode.couchApiBase;
        latest.value = poolDefault;
        cache = poolDefault;
        return poolDefault;
      });
    }
    function clearCache() {
      cache = undefined;
      return this;
    }
    function getFresh(params) {
      return mnPoolDefault.clearCache().get(params);
    }
  }
})();
