(function () {
  "use strict";

  angular.module('mnSettingsCluster', [
    'mnSettingsClusterService',
    'mnHelper',
    'mnPromiseHelper',
    'mnMemoryQuota',
    'mnSpinner'
  ]).controller('mnSettingsClusterController', mnSettingsClusterController);

  function mnSettingsClusterController($scope, $uibModal, mnSettingsClusterService, mnHelper, mnPromiseHelper) {
    var vm = this;
    vm.saveVisualInternalSettings = saveVisualInternalSettings;

    activate();

    $scope.$watch('settingsClusterCtl.state.memoryQuotaConfig', _.debounce(function (memoryQuotaConfig) {
      if (!memoryQuotaConfig) {
        return;
      }
      var promise = mnSettingsClusterService.postPoolsDefault(vm.state.memoryQuotaConfig, true);
      mnPromiseHelper(vm, promise)
        .catchErrorsFromSuccess("memoryQuotaErrors");
    }, 500), true);

    $scope.$watch('settingsClusterCtl.state.indexSettings', _.debounce(function (indexSettings) {
      if (!indexSettings) {
        return;
      }
      var promise = mnSettingsClusterService.postIndexSettings(vm.state.indexSettings, true);
      mnPromiseHelper(vm, promise)
        .catchErrorsFromSuccess("indexSettingsErrors");
    }, 500), true);

    function saveSettings() {
      var promise = mnPromiseHelper(vm, mnSettingsClusterService.postPoolsDefault(vm.state.memoryQuotaConfig, false, vm.state.clusterName))
        .catchErrors("memoryQuotaErrors")
        .getPromise()
        .then(function () {
          return mnPromiseHelper(vm, mnSettingsClusterService.postIndexSettings(vm.state.indexSettings))
            .catchErrors("indexSettingsErrors")
            .getPromise();
        })
      mnPromiseHelper(vm, promise)
        .showSpinner('clusterSettingsLoading')
        .reloadState();
    }
    function saveVisualInternalSettings() {
      if (vm.clusterSettingsLoading) {
        return;
      }
      if (vm.state.initialMemoryQuota != vm.state.memoryQuotaConfig.indexMemoryQuota) {
        $uibModal.open({
          templateUrl: 'app/mn_admin/mn_settings/cluster/mn_settings_cluster_confirmation_dialog.html'
        }).result.then(saveSettings);
      } else {
        saveSettings();
      }
    }
    function activate() {
      mnPromiseHelper(vm, mnSettingsClusterService.getClusterState())
        .applyToScope("state");
    }
  }
})();

