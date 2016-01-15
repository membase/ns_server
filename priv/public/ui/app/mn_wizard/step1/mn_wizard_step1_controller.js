(function () {
  "use strict";
  angular
    .module('mnWizard')
    .controller('mnWizardStep1Controller', mnWizardStep1Controller);

  function mnWizardStep1Controller($scope, $state, $q, mnWizardStep1Service, mnSettingsClusterService, mnAuthService, pools, mnHelper, mnServersService, mnPools, mnPoolDefault, mnAlertsService, mnMemoryQuotaService, mnPromiseHelper) {
    var vm = this;

    vm.joinClusterConfig = mnWizardStep1Service.getJoinClusterConfig();
    vm.joinCluster = 'no';
    vm.isEnterprise = pools.isEnterprise;

    vm.onDbPathChange = onDbPathChange;
    vm.onIndexPathChange = onIndexPathChange;
    vm.isJoinCluster = isJoinCluster;
    vm.onSubmit = onSubmit;

    activate();

    function activate() {
      $scope.$watch('wizardStep1Ctl.startNewClusterConfig.memoryQuota', mnWizardStep1Service.setDynamicRamQuota);

      mnPromiseHelper(vm, mnWizardStep1Service.getSelfConfig())
        .onSuccess(function (selfConfig) {
          vm.selfConfig = selfConfig;
          vm.startNewClusterConfig = {
            maxMemorySize: selfConfig.ramMaxMegs,
            totalMemorySize: selfConfig.ramTotalSize,
            memoryQuota: selfConfig.memoryQuota,
            services: {
              disabled: {kv: true, index: false, n1ql: false, fts: false},
              model: {kv: true, index: true, n1ql: true, fts: true}
            },
            isServicesControllsAvailable: true,
            showKVMemoryQuota: true,
            showIndexMemoryQuota: true,
            indexMemoryQuota: selfConfig.indexMemoryQuota,
            minMemorySize: 256
          };
          vm.hostname = selfConfig.hostname;
          vm.dbPath = selfConfig.storage.hdd[0].path;
          vm.indexPath = selfConfig.storage.hdd[0].index_path;
          vm.onDbPathChange();
          vm.onIndexPathChange();
        });
    }

    function onDbPathChange() {
      vm.dbPathTotal = mnWizardStep1Service.lookup(vm.dbPath, vm.selfConfig.preprocessedAvailableStorage);
    }
    function onIndexPathChange() {
      vm.indexPathTotal = mnWizardStep1Service.lookup(vm.indexPath, vm.selfConfig.preprocessedAvailableStorage);
    }
    function isJoinCluster(value) {
      return vm.joinCluster === value;
    }
    function goNext() {
      $state.go('app.wizard.step2');
    }
    function addErrorHandler(query, name) {
      return mnPromiseHelper(vm, query)
        .catchErrors(name + 'Errors')
        .getPromise();
    }
    function postMemoryQuota() {
      return addErrorHandler(mnSettingsClusterService.postPoolsDefault(vm.startNewClusterConfig), "postMemory");
    }
    function postServices() {
      return addErrorHandler(mnServersService.setupServices({
        services: mnHelper.checkboxesToList(vm.startNewClusterConfig.services.model).join(',')
      }), "setupServices");
    }
    function postDiskStorage() {
      return addErrorHandler(mnWizardStep1Service.postDiskStorage({
        path: vm.dbPath,
        index_path: vm.indexPath
      }), "postDiskStorage");
    }
    function postJoinCluster() {
      var data = _.clone(vm.joinClusterConfig.clusterMember);
      data.services = mnHelper.checkboxesToList(vm.joinClusterConfig.services.model).join(',');
      return addErrorHandler(mnWizardStep1Service.postJoinCluster(data), "postJoinCluster");
    }
    function onSubmit(e) {
      if (vm.viewLoading) {
        return;
      }

      var promise = postDiskStorage().then(function () {
        return addErrorHandler(mnWizardStep1Service.postHostname(vm.hostname), "postHostname");
      }).then(function () {
        if (vm.isJoinCluster('no')) {
          var newClusterParams = vm.startNewClusterConfig;
          var quotaIsChanged = newClusterParams.memoryQuota != vm.selfConfig.memoryQuota || newClusterParams.indexMemoryQuota != vm.selfConfig.indexMemoryQuota;
          var hadServicesString = vm.selfConfig.services.sort().join("");
          var hasServicesString = mnHelper.checkboxesToList(newClusterParams.services.model).sort().join("");
          if (hadServicesString === hasServicesString) {
            if (quotaIsChanged) {
              return postMemoryQuota().then(goNext);
            } else {
              goNext();
            }
          } else {
            if (quotaIsChanged) {
              var hadIndexService = hadServicesString.indexOf("index") > -1;
              var hasIndexService = hasServicesString.indexOf("index") > -1;
              if (hadIndexService && !hasIndexService) {
                return postServices().then(function () {
                  return postMemoryQuota().then(goNext);
                });
              } else {
                return postMemoryQuota().then(function () {
                  return postServices().then(goNext);
                });
              }
            } else {
              return postServices().then(goNext);
            }
          }
        } else {
          return postJoinCluster().then(function () {
            return mnAuthService.login(vm.joinClusterConfig.clusterMember).then(function () {
              return mnPoolDefault.getFresh().then(function (poolsDefault) {
                if (mnMemoryQuotaService.isOnlyOneNodeWithService(poolsDefault.nodes, vm.joinClusterConfig.services.model, 'index')) {
                  $state.go('app.wizard.step6');
                } else {
                  $state.go('app.admin.overview');
                  mnAlertsService.formatAndSetAlerts('This server has been associated with the cluster and will join on the next rebalance operation.', 'success');
                }
              });
            });
          });
        }
      });
      mnPromiseHelper(vm, promise).showErrorsSensitiveSpinner();
    };
  }
})();
