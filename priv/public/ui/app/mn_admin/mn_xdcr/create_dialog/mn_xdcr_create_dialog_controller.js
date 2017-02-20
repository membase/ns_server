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
      vm.advancedFiltering = mnRegexService.getProperties();
      vm.createReplication = createReplication;

      if (vm.mnPoolDefault.value.isEnterprise) {
        try {
          mnRegexService.setProperty("filterExpression", $window.localStorage.getItem('mn_xdcr_regex'));
          mnRegexService.setProperty("testKey", JSON.parse($window.localStorage.getItem('mn_xdcr_testKeys'))[0]);
        } catch (e) {}

        mnRegexService.handleValidateRegex($scope);
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
          .showGlobalSpinner()
          .catchErrors()
          .closeOnSuccess()
          .broadcast("reloadTasksPoller")
          .showGlobalSuccess("Replication created successfully!", 4000);
      };
    }
})();
