angular.module('mnWizardStep1DiskStorageService').factory('mnWizardStep1DiskStorageService',
  function ($http) {

    var preprocessPath;
    var re = /^[A-Z]:\//;
    var mnWizardStep1DiskStorageService = {};
    mnWizardStep1DiskStorageService.model = {
      dbPath: '',
      indexPath: '',
      availableStorage: undefined
    };

    mnWizardStep1DiskStorageService.populateModel = function (conf) {
      if (!conf) {
        return;
      }
      mnWizardStep1DiskStorageService.model.dbPath = conf.hddStorage.path;
      mnWizardStep1DiskStorageService.model.indexPath = conf.hddStorage.index_path;
      preprocessPath = conf.os === 'windows' ? preprocessPathForWindows : preprocessPathStandard;
      mnWizardStep1DiskStorageService.model.availableStorage = _.map(_.clone(conf.availableStorage, true), function (storage) {
        storage.path = preprocessPath(storage.path);
        return storage;
      });
      mnWizardStep1DiskStorageService.model.availableStorage.sort(function (a, b) {
        return b.path.length - a.path.length;
      });
    };

    mnWizardStep1DiskStorageService.lookup = function (path) {
      return path && _.detect(mnWizardStep1DiskStorageService.model.availableStorage, function (info) {
        return preprocessPath(path).substring(0, info.path.length) == info.path;
      }) || {path: "/", sizeKBytes: 0, usagePercent: 0};
    };

    mnWizardStep1DiskStorageService.postDiskStorage = function () {
      return $http({
        method: 'POST',
        url: '/nodes/self/controller/settings',
        data: 'path=' + mnWizardStep1DiskStorageService.model.dbPath +
              '&index_path=' + mnWizardStep1DiskStorageService.model.indexPath,
        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
      });
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

    return mnWizardStep1DiskStorageService;
  });