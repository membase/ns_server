(function () {
  "use strict";

  angular.module('mnSettingsCluster', [
    'mnSettingsClusterService',
    'mnHelper',
    'mnPromiseHelper',
    'mnMemoryQuota',
    'mnStorageMode',
    'mnPoolDefault',
    'mnMemoryQuotaService',
    'mnSpinner'
  ]).controller('mnSettingsClusterController', mnSettingsClusterController);

  function mnSettingsClusterController($scope, $q, $uibModal, mnPoolDefault, mnMemoryQuotaService, mnSettingsClusterService, mnHelper, mnPromiseHelper) {
    var vm = this;
    vm.saveVisualInternalSettings = saveVisualInternalSettings;

    activate();

    $scope.$watch('settingsClusterCtl.memoryQuotaConfig', _.debounce(function (memoryQuotaConfig) {
      if (!memoryQuotaConfig || !$scope.rbac.cluster.pools.write) {
        return;
      }
      var promise = mnSettingsClusterService.postPoolsDefault(vm.memoryQuotaConfig, true);
      mnPromiseHelper(vm, promise)
        .catchErrorsFromSuccess("memoryQuotaErrors");
    }, 500), true);

    if (mnPoolDefault.export.compat.atLeast40) {
      $scope.$watch('settingsClusterCtl.indexSettings', _.debounce(function (indexSettings, prevIndexSettings) {
        if (!indexSettings || !$scope.rbac.cluster.indexes.write || !(prevIndexSettings && !_.isEqual(indexSettings, prevIndexSettings))) {
          return;
        }
        var promise = mnSettingsClusterService.postIndexSettings(vm.indexSettings, true);
        mnPromiseHelper(vm, promise)
          .catchErrorsFromSuccess("indexSettingsErrors");
      }, 500), true);
    }

    function saveSettings() {
      var queries = [];
      var promise1 = mnPromiseHelper(vm, mnSettingsClusterService.postPoolsDefault(vm.memoryQuotaConfig, false, vm.clusterName))
          .catchErrors("memoryQuotaErrors")
          .onSuccess(function () {
            vm.initialMemoryQuota = vm.memoryQuotaConfig.indexMemoryQuota;
          })
          .getPromise();

      queries.push(promise1);

      if (!_.isEqual(vm.indexSettings, vm.initialIndexSettings) && mnPoolDefault.export.compat.atLeast40 && $scope.rbac.cluster.indexes.write) {
        var promise2 = mnPromiseHelper(vm, mnSettingsClusterService.postIndexSettings(vm.indexSettings))
            .catchErrors("indexSettingsErrors")
            .applyToScope("initialIndexSettings")
            .getPromise();

        queries.push(promise2);
      }

      var promise3 = $q.all(queries);
      mnPromiseHelper(vm, promise3)
        .showGlobalSpinner()
        .showGlobalSuccess("Settings saved successfully!");
    }
    function saveVisualInternalSettings() {
      if (vm.clusterSettingsLoading) {
        return;
      }
      if ((!vm.indexSettings || vm.indexSettings.storageMode === "forestdb") && vm.initialMemoryQuota != vm.memoryQuotaConfig.indexMemoryQuota) {
        $uibModal.open({
          templateUrl: 'app/mn_admin/mn_settings/cluster/mn_settings_cluster_confirmation_dialog.html'
        }).result.then(saveSettings);
      } else {
        saveSettings();
      }
    }
    function activate() {
      mnPromiseHelper(vm, mnPoolDefault.get())
        .applyToScope(function (resp) {
          vm.clusterName = resp.clusterName;
        });

      mnPromiseHelper(vm, mnMemoryQuotaService.memoryQuotaConfig({
        kv: true,
        index: mnPoolDefault.export.compat.atLeast40,
        fts: mnPoolDefault.export.compat.atLeast45,
        n1ql: mnPoolDefault.export.compat.atLeast40
      }, false, false))
        .applyToScope(function (resp) {
          vm.initialMemoryQuota = resp.indexMemoryQuota;
          vm.memoryQuotaConfig = resp;
        });

      if (mnPoolDefault.export.compat.atLeast40 && $scope.rbac.cluster.indexes.read) {
        mnPromiseHelper(vm, mnSettingsClusterService.getIndexSettings())
          .applyToScope(function (indexSettings) {
            vm.indexSettings = indexSettings;
            vm.initialIndexSettings = _.clone(indexSettings);
          });
      }
    }
  }
})();
