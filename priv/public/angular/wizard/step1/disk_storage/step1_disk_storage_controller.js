angular.module('wizard')
  .controller('wizard.step1.diskStorage.Controller',
    ['wizard.step1.service', '$scope', 'wizard.step1.diskStorage.service',
      function (step1Service, $scope, diskStorageService) {
        $scope.modelDiskStorageService = diskStorageService.model;

        function updateTotal(pathResource) {
          return (Math.floor(pathResource.sizeKBytes * (100 - pathResource.usagePercent) / 100 / Math.Mi)) + ' GB';
        }

        $scope.$watch('modelDiskStorageService.dbPath', function (pathValue) {
          $scope.dbPathTotal = updateTotal(diskStorageService.lookup(pathValue));
        });
        $scope.$watch('modelDiskStorageService.indexPath', function (pathValue) {
          $scope.indexPathTotal = updateTotal(diskStorageService.lookup(pathValue));
        });

        $scope.$watch(function () {
          if (!step1Service.model.nodeConfig) {
            return;
          }
          var nodeConfig = step1Service.model.nodeConfig;
          return {
            os: nodeConfig.os,
            hddStorage: nodeConfig.storage.hdd[0],
            availableStorage: nodeConfig.availableStorage.hdd
          };
        }, diskStorageService.populateModel, true);
      }]);