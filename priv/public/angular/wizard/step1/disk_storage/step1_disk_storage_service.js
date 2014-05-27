angular.module('wizard.step1.diskStorage.service', [])
  .factory('wizard.step1.diskStorage.service',
    ['$http', function ($http) {

        var preprocessPath;
        var re = /^[A-Z]:\//;
        var scope = {};
        scope.model = {
          dbPath: '',
          indexPath: '',
          availableStorage: undefined
        };

        scope.populateModel = function populateModel(conf) {
          if (!conf) {
            return;
          }
          scope.model.dbPath = conf.hddStorage.path;
          scope.model.indexPath = conf.hddStorage.index_path;
          preprocessPath = conf.os === 'windows' ? preprocessPathForWindows : preprocessPathStandard;
          scope.model.availableStorage = _.map(_.clone(conf.availableStorage, true), function (storage) {
            storage.path = preprocessPath(storage.path);
            return storage;
          });
          scope.model.availableStorage.sort(function (a, b) {
            return b.path.length - a.path.length;
          });
        };

        scope.lookup = function lookup(path) {
          return path && _.detect(scope.model.availableStorage, function (info) {
            return preprocessPath(path).substring(0, info.path.length) == info.path;
          }) || {path: "/", sizeKBytes: 0, usagePercent: 0};
        };

        scope.postDiskStorage = function postDiskStorage() {
          return $http({
            method: 'POST',
            url: '/nodes/self/controller/settings',
            data: 'path=' + scope.model.dbPath + '&index_path=' + scope.model.indexPath,
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

        return scope;
      }]);