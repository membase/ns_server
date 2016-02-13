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
      mnPromiseHelper(vm, mnWizardStep1Service.getConfig())
      .applyToScope("config")
      .onSuccess(function (config) {
        vm.onDbPathChange();
        vm.onIndexPathChange();
      });
    }

    function onDbPathChange() {
      vm.dbPathTotal = mnWizardStep1Service.lookup(vm.config.dbPath, vm.config.selfConfig.preprocessedAvailableStorage);
    }
    function onIndexPathChange() {
      vm.indexPathTotal = mnWizardStep1Service.lookup(vm.config.indexPath, vm.config.selfConfig.preprocessedAvailableStorage);
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
      return addErrorHandler(mnSettingsClusterService.postPoolsDefault(vm.config.startNewClusterConfig), "postMemory");
    }
    function validateIndexSettings() {
      return mnPromiseHelper(vm, mnSettingsClusterService.postIndexSettings(vm.config.startNewClusterConfig.indexSettings, true))
        .catchErrorsFromSuccess('postIndexSettingsErrors')
        .getPromise();
    }
    function postServices() {
      return addErrorHandler(mnServersService.setupServices({
        services: mnHelper.checkboxesToList(vm.config.startNewClusterConfig.services.model).join(',')
      }), "setupServices");
    }
    function postDiskStorage() {
      return addErrorHandler(mnWizardStep1Service.postDiskStorage({
        path: vm.config.dbPath,
        index_path: vm.config.indexPath
      }), "postDiskStorage");
    }
    function postJoinCluster() {
      var data = _.clone(vm.joinClusterConfig.clusterMember);
      data.services = mnHelper.checkboxesToList(vm.joinClusterConfig.services.model).join(',');
      return addErrorHandler(mnWizardStep1Service.postJoinCluster(data), "postJoinCluster");
    }
    function doStartNewCluster() {
      var newClusterParams = vm.config.startNewClusterConfig;
      var quotaIsChanged = newClusterParams.memoryQuota != vm.config.selfConfig.memoryQuota || newClusterParams.indexMemoryQuota != vm.config.selfConfig.indexMemoryQuota;
      var hadServicesString = vm.config.selfConfig.services.sort().join("");
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
    }
    function onSubmit(e) {
      if (vm.viewLoading) {
        return;
      }
      delete vm.setupServicesErrors;
      delete vm.postMemoryErrors;
      delete vm.postDiskStorageErrors;
      delete vm.postJoinClusterErrors;
      delete vm.postHostnameErrors;
      delete vm.postIndexSettingsErrors;

      var promise = postDiskStorage().then(function () {
        return addErrorHandler(mnWizardStep1Service.postHostname(vm.config.hostname), "postHostname");
      }).then(function () {
        if (vm.isJoinCluster('no')) {
          if (vm.config.startNewClusterConfig.services.model.index) {
            return validateIndexSettings().then(function () {
              if (vm.postIndexSettingsErrors) {
                return $q.reject();
              }
              return doStartNewCluster();
            });
          } else {
            return doStartNewCluster();
          }
        } else {
          return postJoinCluster().then(function () {
            return mnAuthService.login(vm.joinClusterConfig.clusterMember).then(function () {
              return mnPoolDefault.getFresh().then(function (poolsDefault) {
                var firstTimeAddedNodes = mnMemoryQuotaService.getFirstTimeAddedNodes(["index", "fts"], vm.joinClusterConfig.services.model, poolsDefault.nodes);
                vm.joinClusterConfig.firstTimeAddedNodes = firstTimeAddedNodes;
                if (firstTimeAddedNodes.count) {
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
