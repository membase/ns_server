angular.module('mnWizard').controller('mnWizardStep1DiskStorageController',
  function ($scope, mnWizardStep1Service, mnWizardStep1DiskStorageService) {
    $scope.mnWizardStep1DiskStorageServiceModel = mnWizardStep1DiskStorageService.model;

    function updateTotal(pathResource) {
      return (Math.floor(pathResource.sizeKBytes * (100 - pathResource.usagePercent) / 100 / Math.Mi)) + ' GB';
    }

    $scope.$watch('mnWizardStep1DiskStorageServiceModel.dbPath', function (pathValue) {
      $scope.dbPathTotal = updateTotal(mnWizardStep1DiskStorageService.lookup(pathValue));
    });
    $scope.$watch('mnWizardStep1DiskStorageServiceModel.indexPath', function (pathValue) {
      $scope.indexPathTotal = updateTotal(mnWizardStep1DiskStorageService.lookup(pathValue));
    });

    $scope.$watch(function () {
      if (!mnWizardStep1Service.model.nodeConfig) {
        return;
      }
      var nodeConfig = mnWizardStep1Service.model.nodeConfig;
      return {
        os: nodeConfig.os,
        hddStorage: nodeConfig.storage.hdd[0],
        availableStorage: nodeConfig.availableStorage.hdd
      };
    }, mnWizardStep1DiskStorageService.populateModel, true);
  });