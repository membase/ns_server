(function () {
  "use strict";

  angular
    .module('mnServers')
    .controller('mnServersAddDialogController', mnServersAddDialogController)

  function mnServersAddDialogController($scope, $q, $uibModal, mnServersService, $uibModalInstance, mnHelper, mnPromiseHelper, groups, mnPoolDefault, mnMemoryQuotaService) {
    var vm = this;

    vm.addNodeConfig = {
      services: {
        model: {
          kv: true,
          index: true,
          n1ql: true,
          fts: $scope.poolDefault.compat.atLeast45
        }
      },
      credentials: {
        hostname: '',
        user: 'Administrator',
        password: ''
      }
    };
    vm.isGroupsAvailable = !!groups;
    vm.onSubmit = onSubmit;
    if (vm.isGroupsAvailable) {
      vm.addNodeConfig.selectedGroup = groups.groups[0];
      vm.groups = groups.groups;
    }

    activate();

    function activate() {
      reset();
    }
    function reset() {
      vm.focusMe = true;
    }
    function onSubmit(form) {
      if (vm.viewLoading) {
        return;
      }

      var servicesList = mnHelper.checkboxesToList(vm.addNodeConfig.services.model);

      form.$setValidity('services', !!servicesList.length);

      if (form.$invalid) {
        return reset();
      }

      var promise = mnServersService.addServer(vm.addNodeConfig.selectedGroup, vm.addNodeConfig.credentials, servicesList);

      mnPromiseHelper(vm, promise, $uibModalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .closeOnSuccess()
        .broadcast("reloadServersPoller")
        .getPromise()
        .then(function () {
          return mnPromiseHelper(vm, mnPoolDefault.get())
            .getPromise()
            .then(function (poolsDefault) {
              var firstTimeAddedServices = mnMemoryQuotaService.getFirstTimeAddedServices(["index", "fts"], vm.addNodeConfig.services.model, poolsDefault.nodes);
              if (firstTimeAddedServices.count) {
                return $uibModal.open({
                  windowTopClass: "without-titlebar-close",
                  templateUrl: 'app/mn_admin/mn_servers/memory_quota_dialog/memory_quota_dialog.html',
                  controller: 'mnServersMemoryQuotaDialogController as serversMemoryQuotaDialogCtl',
                  resolve: {
                    memoryQuotaConfig: function (mnMemoryQuotaService) {
                      return mnMemoryQuotaService.memoryQuotaConfig(vm.addNodeConfig.services.model)
                    },
                    indexSettings: function (mnSettingsClusterService) {
                      return mnSettingsClusterService.getIndexSettings();
                    },
                    firstTimeAddedServices: function() {
                      return firstTimeAddedServices;
                    }
                  }
                }).result;
              }
            });
        });
    };
  }
})();

