(function () {
  "use strict";

  angular
    .module('mnPoolDefault', [
      'mnPools'
    ])
    .factory('mnPoolDefault', mnPoolDefaultFactory);

  function mnPoolDefaultFactory($http, $q, mnPools, $window, $location, $httpParamSerializerJQLike, mnHelper) {
    var latest = {};
    var mnPoolDefault = {
      latestValue: latestValue,
      get: get,
      clearCache: clearCache,
      getFresh: getFresh,
      getUrlsRunningService: getUrlsRunningService,
      export: {
        compat: undefined
      }
    };
    var version25 = encodeCompatVersion(2, 5);
    var version30 = encodeCompatVersion(3, 0);
    var version40 = encodeCompatVersion(4, 0);
    var version45 = encodeCompatVersion(4, 5);
    var version46 = encodeCompatVersion(4, 6);
    var version50 = encodeCompatVersion(5, 0);
    var cache;
    var request;

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
      if (request && !cache) {
        return request;
      }
      params = params || {waitChange: 0};
      request = $q.all([
        $http({
          mnHttp: mnHttpParams,
          method: 'GET',
          url: '/pools/default',
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
        poolDefault.compat = {
          atLeast25: poolDefault.thisNode.clusterCompatibility >= version25,
          atLeast30: poolDefault.thisNode.clusterCompatibility >= version30,
          atLeast40: poolDefault.thisNode.clusterCompatibility >= version40,
          atLeast45: poolDefault.thisNode.clusterCompatibility >= version45,
          atLeast46: poolDefault.thisNode.clusterCompatibility >= version46,
          atLeast50: poolDefault.thisNode.clusterCompatibility >= version50
        };
        poolDefault.isKvNode =  _.indexOf(poolDefault.thisNode.services, "kv") > -1;
        poolDefault.capiBase = $window.location.protocol === "https:" ? poolDefault.thisNode.couchApiBaseHTTPS : poolDefault.thisNode.couchApiBase;

        _.extend(mnPoolDefault.export, poolDefault);
        latest.value = poolDefault; //deprecated and superseded by mnPoolDefault.export
        cache = poolDefault;

        return poolDefault;
      }, function (resp) {
        if ((resp.status === 404 && resp.data === "unknown pool") || resp.status === 500) {
          mnHelper.reloadApp();
        }
        return $q.reject(resp);
      });
      return request;
    }
    function clearCache() {
      cache = undefined;
      request = undefined;
      return this;
    }
    function getFresh(params) {
      return mnPoolDefault.clearCache().get(params);
    }
    /**
     * getUrlsRunningService - returns a list of URLs for nodes in the cluster
     *   running the named service. It assumes that you are currently on a page
     *   associated with the service, and it appends the path for the current page
     *   to the URL.
     *
     * @param nodeInfos - details on the nodes in the cluster returned
     *                    by
     * @param service - name of service
     * @param max - optional max number of links to return
     *
     * @return a list of URLs for the current UI location running the
     *         specified service.
     */
    function getUrlsRunningService(nodeInfos, service, max) {
      var nodes = _.filter(nodeInfos, function (node) {
        return _.indexOf(node.services, service) > -1
          && node.clusterMembership === 'active';
      });
      if (max && max < nodes.length) {
        nodes = nodes.slice(0, max);
      }
      var protocol = $location.protocol();
      var appbase = $window.location.pathname;
      var search = $httpParamSerializerJQLike($location.search());
      var hash = $location.hash();
      return _.map(nodes, function(node) {
        var hostnameAndPort = node.hostname.split(':');
        var port = protocol == "https" ? node.ports.httpsMgmt : hostnameAndPort[1];
        return protocol
          + "://" + hostnameAndPort[0]
          + ":" + port
          + appbase
          + "#!" + $location.path()
          + (search ? "?" + search : "")
          + (hash ? "#" + hash : "");
      });
    }
  }
})();
