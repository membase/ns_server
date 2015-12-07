(function () {
  "use strict";

  angular.module('mnWizardStep1Service', [
    'mnHelper'
  ]).factory('mnWizardStep1Service', mnWizardStep1ServiceFactory);

  function mnWizardStep1ServiceFactory($http, mnHelper, IEC) {
    var mnWizardStep1Service = {
      setDynamicRamQuota: setDynamicRamQuota,
      getDynamicRamQuota: getDynamicRamQuota,
      getJoinClusterConfig: getJoinClusterConfig,
      getNewClusterConfig: getNewClusterConfig,
      getSelfConfig: getSelfConfig,
      postDiskStorage: postDiskStorage,
      postHostname: postHostname,
      postJoinCluster: postJoinCluster,
      lookup: lookup
    };
    var re = /^[A-Z]:\//;
    var preprocessPath;
    var dynamicRamQuota;
    var joinClusterConfig = {
      clusterMember: {
        hostname: "127.0.0.1",
        username: "Administrator",
        password: ''
      },
      services: {
        disabled: {kv: false, index: false, n1ql: false, fts: false},
        model: {kv: true, index: true, n1ql: true, fts: true}
      }
    };

    return mnWizardStep1Service;

    function setDynamicRamQuota(ramQuota) {
      dynamicRamQuota = ramQuota;
    }
    function getDynamicRamQuota() {
      return dynamicRamQuota;
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
    function getNewClusterConfig() {
      return getNewClusterConfig;
    }
    function getSelfConfig() {
      return $http({
        method: 'GET',
        url: '/nodes/self',
        responseType: 'json'
      }).then(function (resp) {
        var nodeConfig = resp.data;
        var ram = nodeConfig.storageTotals.ram;
        var totalRAMMegs = Math.floor(ram.total / IEC.Mi);
        preprocessPath = nodeConfig.os === 'windows' ? preprocessPathForWindows : preprocessPathStandard;
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
