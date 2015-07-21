angular.module('mnSettingsNotificationsService', [
  'mnHttp',
  'mnPoolDefault',
  'mnBucketsService',
  'mnPools'
]).factory('mnSettingsNotificationsService',
  function (mnHttp, mnPoolDefault, mnBucketsService, mnPools, $q, $window, $rootScope) {
    var mnSettingsNotificationsService = {};

    function buildPhoneHomeThingy(infos) {
      var buckets = infos[1];
      var poolsDefault = infos[0];
      var pools = infos[2];

      return {
        version: pools.implementationVersion,
        componentsVersion: pools.componentsVersion,
        uuid: pools.uuid,
        numNodes: poolsDefault.nodes.length,
        ram: {
          total: poolsDefault.storageTotals.ram.total,
          quotaTotal: poolsDefault.storageTotals.ram.quotaTotal,
          quotaUsed: poolsDefault.storageTotals.ram.quotaUsed
        },
        hdd: {
          total: poolsDefault.storageTotals.hdd.total,
          quotaTotal: poolsDefault.storageTotals.hdd.quotaTotal,
          used: poolsDefault.storageTotals.hdd.used,
          usedByData: poolsDefault.storageTotals.hdd.usedByData
        },
        buckets: {
          total: buckets.length,
          membase: buckets.byType.membase.length,
          memcached: buckets.byType.memcached.length
        },
        counters: poolsDefault.counters,
        nodes: {
          os: _.pluck(poolsDefault.nodes, 'os'),
          uptime: _.pluck(poolsDefault.nodes, 'uptime'),
          istats: _.pluck(poolsDefault.nodes, 'interestingStats')
        },
        browser: $window.navigator.userAgent
      };
    }

    mnSettingsNotificationsService.buildPhoneHomeThingy = function () {
      return $q.all([
        mnPoolDefault.getFresh(),
        mnBucketsService.getBucketsByType(),
        mnPools.get()
      ]).then(buildPhoneHomeThingy);
    };

    mnSettingsNotificationsService.getUpdates = function (data) {
      return mnHttp({
        method: 'JSONP',
        url: 'http://ph.couchbase.net/v2',
        timeout: 8000,
        params: {launchID: data.launchID, version: data.version, callback: 'JSON_CALLBACK'}
      });
    };

    mnSettingsNotificationsService.maybeCheckUpdates = function () {
      return mnSettingsNotificationsService.getSendStatsFlag().then(function (sendStatsData) {
        if (!sendStatsData.sendStats) {
          return sendStatsData;
        } else {
          return mnPools.get().then(function (pools) {
            return mnSettingsNotificationsService.getUpdates({
              launchID: pools.launchID,
              version: pools.version
            }).then(function (resp) {
              return _.extend(_.clone(resp.data), sendStatsData);
            }, function (resp) {
              return sendStatsData;
            });
          });
        }
      })
    };

    mnSettingsNotificationsService.saveSendStatsFlag = function (flag) {
      return mnHttp.post("/settings/stats", {sendStats: flag});
    };
    mnSettingsNotificationsService.getSendStatsFlag = function () {
      return mnHttp.get("/settings/stats").then(function (resp) {
        return resp.data;
      });
    };


    return mnSettingsNotificationsService;
});