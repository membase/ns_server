(function () {
  "use strict";

  angular.module('mnClusterConfigurationService', [
    'mnHelper',
    'mnPools'
  ]).factory('mnClusterConfigurationService', mnClusterConfigurationServiceFactory);

  function mnClusterConfigurationServiceFactory($http, mnHelper, IEC, mnPools) {
    var mnClusterConfigurationService = {
      getDynamicRamQuota: getDynamicRamQuota,
      getJoinClusterConfig: getJoinClusterConfig,
      getNewClusterConfig: getNewClusterConfig,
      getSelfConfig: getSelfConfig,
      postDiskStorage: postDiskStorage,
      postHostname: postHostname,
      postJoinCluster: postJoinCluster,
      lookup: lookup,
      getConfig: getConfig,
      postAuth: postAuth,
      postEmail: postEmail,
      postStats: postStats,
      getQuerySettings: getQuerySettings,
      postQuerySettings: postQuerySettings
    };
    var re = /^[A-Z]:\//;
    var preprocessPath;

    var joinClusterConfig = {
      clusterMember: {
        hostname: "127.0.0.1",
        username: "Administrator",
        password: ''
      },
      services: {
        disabled: {kv: false, index: false, n1ql: false, fts: false, eventing: false, cbas: false},
        model: {kv: true, index: true, n1ql: true, fts: true, eventing: true, cbas: false}
      },
      firstTimeAddedServices: undefined
    };
    var newConfig = {
      maxMemorySize: undefined,
      totalMemorySize: undefined,
      memoryQuota: undefined,
      displayedServices: {kv: true, index: true, fts: true, n1ql: true, eventing: true, cbas: true},
      services: {
        disabled: {kv: true, index: false, n1ql: false, fts: false, eventing: false, cbas: false},
        model: {kv: true, index: true, n1ql: true, fts: true, eventing: true, cbas: false}
      },
      showKVMemoryQuota: true,
      showIndexMemoryQuota: true,
      showFTSMemoryQuota: true,
      showEventingMemoryQuota: true,
      showCBASMemoryQuota: true,
      indexMemoryQuota: undefined,
      ftsMemoryQuota: undefined,
      eventingMemoryQuota: undefined,
      cbasMemoryQuota: undefined,
      minMemorySize: 256,
      indexSettings: {
        storageMode: mnPools.export.isEnterprise ? "plasma" : "forestdb"
      }
    };

    return mnClusterConfigurationService;

    function getQuerySettings() {
      return $http({
        method: 'GET',
        url: '/settings/querySettings'
      }).then(function (resp) {
        return resp.data;
      });
    }

    function postQuerySettings(data) {
      return $http({
        method: 'POST',
        url: '/settings/querySettings',
        data: data
      }).then(function (resp) {
        return resp.data;
      });
    }

    function postStats(user, sendStats) {
      user.email && postEmail(user);
      return doPostStats({sendStats: sendStats});
    }

    function postEmail(register) {
      var params = _.clone(register);
      delete params.agree;

      return $http({
        method: 'JSONP',
        url: 'https://ph.couchbase.net/email',
        params: params
      });
    }
    function doPostStats(data) {
      return $http({
        method: 'POST',
        url: '/settings/stats',
        data: data
      });
    }

    function postAuth(user, justValidate) {
      var data = _.clone(user);
      delete data.verifyPassword;
      data.port = "SAME";

      return $http({
        method: 'POST',
        url: '/settings/web',
        data: data,
        params: {
          just_validate: justValidate ? 1 : 0
        }
      });
    }

    function getConfig() {
      return mnClusterConfigurationService.getSelfConfig().then(function (resp) {
        var selfConfig = resp;
        var rv = {};
        rv.selfConfig = selfConfig;

        newConfig.maxMemorySize = selfConfig.ramMaxMegs;
        newConfig.totalMemorySize = selfConfig.ramTotalSize;
        newConfig.memoryQuota = selfConfig.memoryQuota;
        newConfig.indexMemoryQuota = selfConfig.indexMemoryQuota;
        newConfig.ftsMemoryQuota = selfConfig.ftsMemoryQuota;
        newConfig.eventingMemoryQuota = selfConfig.eventingMemoryQuota;
        newConfig.cbasMemoryQuota = selfConfig.cbasMemoryQuota;
        newConfig.calculateTotal = true;

        rv.startNewClusterConfig = newConfig;
        rv.hostname = selfConfig.hostname;
        rv.dbPath = selfConfig.storage.hdd[0].path;
        rv.indexPath = selfConfig.storage.hdd[0].index_path;
        rv.cbasDirs = selfConfig.storage.hdd[0].cbas_dirs;
        return rv;
      });
    }
    function getDynamicRamQuota() {
      return newConfig.memoryQuota;
    }
    function getNewClusterConfig() {
      return newConfig;
    }

    function preprocessPathStandard(p) {
      if (p.charAt(p.length-1) != '/') {
        p += '/';
      }
      return p;
    }
    function preprocessPathForWindows(p) {
      p = p.replace(/\\/g, '/');
      if (re.exec(p)) { // if we're using uppercase drive letter downcase it
        p = String.fromCharCode(p.charCodeAt(0) + 0x20) + p.slice(1);
      }
      return preprocessPathStandard(p);
    }
    function updateTotal(pathResource) {
      return (Math.floor(pathResource.sizeKBytes * (100 - pathResource.usagePercent) / 100 / IEC.Mi)) + ' GB';
    }
    function getJoinClusterConfig() {
      return joinClusterConfig;
    }
    function getSelfConfig() {
      return $http({
        method: 'GET',
        url: '/nodes/self'
      }).then(function (resp) {
        var nodeConfig = resp.data;
        var ram = nodeConfig.storageTotals.ram;
        var totalRAMMegs = Math.floor(ram.total / IEC.Mi);
        preprocessPath = (nodeConfig.os === 'windows' || nodeConfig.os === 'win64' || nodeConfig.os === 'win32') ? preprocessPathForWindows : preprocessPathStandard;
        nodeConfig.preprocessedAvailableStorage = _.map(_.clone(nodeConfig.availableStorage.hdd, true), function (storage) {
          storage.path = preprocessPath(storage.path);
          return storage;
        }).sort(function (a, b) {
          return b.path.length - a.path.length;
        });

        nodeConfig.ramTotalSize = totalRAMMegs;
        nodeConfig.ramMaxMegs = mnHelper.calculateMaxMemorySize(totalRAMMegs);

        nodeConfig.hostname = (nodeConfig && nodeConfig['otpNode'].split('@')[1]) || '127.0.0.1';

        return nodeConfig;
      });
    }
    function lookup(path, availableStorage) {
      return updateTotal(path && _.detect(availableStorage, function (info) {
        return preprocessPath(path).substring(0, info.path.length) == info.path;
      }) || {path: "/", sizeKBytes: 0, usagePercent: 0});
    }
    function postDiskStorage(config) {
      return $http({
        method: 'POST',
        url: '/nodes/self/controller/settings',
        data: config
      });
    }
    function postHostname(hostname) {
      return $http({
        method: 'POST',
        url: '/node/controller/rename',
        data: {hostname: hostname}
      });
    }
    function postJoinCluster(clusterMember) {
      clusterMember.user = clusterMember.username;
      return $http({
        method: 'POST',
        url: '/node/controller/doJoinCluster',
        data: clusterMember
      });
    }
  }
})();
