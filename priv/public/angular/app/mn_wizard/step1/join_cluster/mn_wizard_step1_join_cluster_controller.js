angular.module('mnWizard').controller('mnWizardStep1JoinClusterController',
  function (mnWizardStep1Service, $scope, mnWizardStep1JoinClusterService, $timeout) {
    $scope.mnWizardStep1JoinClusterServiceModel = mnWizardStep1JoinClusterService.model;

    $scope.$watch(function () {
      if (!mnWizardStep1Service.model.nodeConfig) {
        return;
      }
      return mnWizardStep1Service.model.nodeConfig.storageTotals.ram;
    }, mnWizardStep1JoinClusterService.populateModel, true);
  });