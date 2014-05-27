angular.module('wizard')
  .controller('wizard.step1.joinCluster.Controller',
    ['wizard.step1.service', '$scope', 'wizard.step1.joinCluster.service',
      function (step1Service, $scope, joinClusterService) {
        $scope.modelJoinClusterService = joinClusterService.model;
        $scope.focusMe = true;
        $scope.$watch(function () {
          if (!step1Service.model.nodeConfig) {
            return;
          }
          return step1Service.model.nodeConfig.storageTotals.ram;
        }, joinClusterService.populateModel, true);
      }]);