(function () {
  "use strict";

  angular
    .module('mnXDCR')
    .controller('mnXDCRCreateDialogController', mnXDCRCreateDialogController);

    function mnXDCRCreateDialogController($scope, $uibModalInstance, $timeout, $window, mnPromiseHelper, mnPoolDefault, mnXDCRService, buckets, replicationSettings, mnRegexService) {
      var vm = this;

      vm.replication = replicationSettings.data;
      vm.mnPoolDefault = mnPoolDefault.latestValue();
      delete vm.replication.socketOptions;
      vm.replication.replicationType = "continuous";
      vm.replication.type = "xmem";
      vm.buckets = buckets.byType.membase;
      vm.replication.fromBucket = vm.buckets[0].name;
      vm.replication.toCluster = $scope.mnXDCRController.mnXdcrState.references[0].name;
      vm.advancedFiltering = {};
      vm.createReplication = createReplication;

      if (vm.mnPoolDefault.value.isEnterprise) {
        try {
          vm.advancedFiltering.filterExpression = $window.localStorage.getItem('mn_xdcr_regex');
          vm.advancedFiltering.testKey = JSON.parse($window.localStorage.getItem('mn_xdcr_testKeys'))[0];
        } catch (e) {}

        mnRegexService.handleValidateRegex($scope, vm.advancedFiltering);
      }

      function createReplication() {
        var replication = mnXDCRService.removeExcessSettings(vm.replication);
        if (vm.mnPoolDefault.value.isEnterprise) {
          if (vm.replication.enableAdvancedFiltering) {
            var filterExpression = vm.advancedFiltering.filterExpression;
          }
          replication.filterExpression = filterExpression;
        }
        var promise = mnXDCRService.postRelication(replication);
        mnPromiseHelper(vm, promise, $uibModalInstance)
          .showErrorsSensitiveSpinner()
          .cancelOnScopeDestroy($scope)
          .catchErrors()
          .closeOnSuccess()
          .reloadState();
      };
    }
})();

