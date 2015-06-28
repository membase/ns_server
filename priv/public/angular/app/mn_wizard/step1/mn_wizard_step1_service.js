angular.module('mnWizardStep1Service', [
  'mnHttp'
]).factory('mnWizardStep1Service',
  function (mnHttp) {

    var mnWizardStep1Service = {};
    var re = /^[A-Z]:\//;
    var preprocessPath;
    var dynamicRamQuota;

    mnWizardStep1Service.setDynamicRamQuota = function (ramQuota) {
      dynamicRamQuota = ramQuota;
    };
    mnWizardStep1Service.getDynamicRamQuota = function () {
      return dynamicRamQuota;
    };

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
      return (Math.floor(pathResource.sizeKBytes * (100 - pathResource.usagePercent) / 100 / Math.Mi)) + ' GB';
    }

    mnWizardStep1Service.getSelfConfig = function () {
      return mnHttp({
        method: 'GET',
        url: '/nodes/self',
        responseType: 'json'
      }).then(function (resp) {
        var nodeConfig = resp.data;
        var ram = nodeConfig.storageTotals.ram;
        var totalRAMMegs = Math.floor(ram.total / Math.Mi);
        preprocessPath = nodeConfig.os === 'windows' ? preprocessPathForWindows : preprocessPathStandard;
        nodeConfig.preprocessedAvailableStorage = _.map(_.clone(nodeConfig.availableStorage.hdd, true), function (storage) {
          storage.path = preprocessPath(storage.path);
          return storage;
        }).sort(function (a, b) {
          return b.path.length - a.path.length;
        });

        nodeConfig.dynamicRamQuota = Math.floor(ram.quotaTotal / Math.Mi);
        nodeConfig.ramTotalSize = totalRAMMegs;
        nodeConfig.ramMaxMegs = Math.max(totalRAMMegs - 1024, Math.floor(ram.total * 4 / (5 * Math.Mi)));

        nodeConfig.hostname = (nodeConfig && nodeConfig['otpNode'].split('@')[1]) || '127.0.0.1';

        return nodeConfig;
      });
    };

    mnWizardStep1Service.lookup = function (path, availableStorage) {

      return updateTotal(path && _.detect(availableStorage, function (info) {
        return preprocessPath(path).substring(0, info.path.length) == info.path;
      }) || {path: "/", sizeKBytes: 0, usagePercent: 0});
    };

    mnWizardStep1Service.postDiskStorage = function (config) {
      return mnHttp({
        method: 'POST',
        url: '/nodes/self/controller/settings',
        data: config
      });
    };

    mnWizardStep1Service.postHostname = function (hostname) {
      return mnHttp({
        method: 'POST',
        url: '/node/controller/rename',
        data: {hostname: hostname}
      });
    };

    mnWizardStep1Service.postMemory = function (memoryQuota) {
      return mnHttp({
        method: 'POST',
        url: '/pools/default',
        data: {memoryQuota: memoryQuota}
      });
    };

    mnWizardStep1Service.postJoinCluster = function (clusterMember) {
      clusterMember.user = clusterMember.username;
      return mnHttp({
        method: 'POST',
        url: '/node/controller/doJoinCluster',
        data: clusterMember
      });
    };

    return mnWizardStep1Service;
  });