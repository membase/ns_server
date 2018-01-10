(function () {
  "use strict";
  angular
    .module('mnWizard')
    .controller('mnClusterConfigurationController', mnClusterConfigurationController);

  function mnClusterConfigurationController($scope, $rootScope, $state, $q, mnClusterConfigurationService, mnSettingsClusterService, mnAuthService, pools, mnHelper, mnServersService, mnPools, mnAlertsService, mnPromiseHelper, mnWizardService) {
    var vm = this;

    vm.joinClusterConfig = mnClusterConfigurationService.getJoinClusterConfig();
    vm.defaultJoinClusterSerivesConfig = _.clone(vm.joinClusterConfig.services, true);
    vm.isEnterprise = pools.isEnterprise;

    vm.onDbPathChange = onDbPathChange;
    vm.onIndexPathChange = onIndexPathChange;
    vm.onSubmit = onSubmit;
    vm.sendStats = true;

    activate();

    function activate() {
      mnPromiseHelper(vm, mnClusterConfigurationService.getConfig())
        .applyToScope("config")
        .onSuccess(function (config) {
          vm.defaultConfig = _.clone(config);
          vm.onDbPathChange();
          vm.onIndexPathChange();
        });

      mnPromiseHelper(vm, mnClusterConfigurationService.getQuerySettings())
        .applyToScope("querySettings");

      $scope.$watch('clusterConfigurationCtl.config.startNewClusterConfig', _.debounce(onMemoryQuotaChanged, 500), true);
    }

    function onMemoryQuotaChanged(memoryQuotaConfig) {
      if (!memoryQuotaConfig) {
        return;
      }
      var promise = mnSettingsClusterService.postPoolsDefault(memoryQuotaConfig, true);
      mnPromiseHelper(vm, promise)
        .catchErrorsFromSuccess("postMemoryErrors");
    }
    function onDbPathChange() {
      vm.dbPathTotal = mnClusterConfigurationService.lookup(vm.config.dbPath, vm.config.selfConfig.preprocessedAvailableStorage);
    }
    function onIndexPathChange() {
      vm.indexPathTotal = mnClusterConfigurationService.lookup(vm.config.indexPath, vm.config.selfConfig.preprocessedAvailableStorage);
    }
    function goNext() {
      var newClusterState = mnWizardService.getNewClusterState();
      return mnClusterConfigurationService.postAuth(newClusterState.user).then(function () {
        return mnAuthService.login(newClusterState.user).then(function () {
          var config = mnClusterConfigurationService.getNewClusterConfig();
          if (config.services.model.index) {
            mnSettingsClusterService.postIndexSettings(config.indexSettings);
          }
        }).then(function () {
          return $state.go('app.admin.overview');
        });
      });
    }
    function addErrorHandler(query, name) {
      return mnPromiseHelper(vm, query)
        .catchErrors(name + 'Errors')
        .getPromise();
    }
    function postMemoryQuota() {
      var data = _.clone(vm.config.startNewClusterConfig);
      var newClusterState = mnWizardService.getNewClusterState();
      !vm.config.startNewClusterConfig.services.model.index && (delete data.indexMemoryQuota);
      !vm.config.startNewClusterConfig.services.model.fts && (delete data.ftsMemoryQuota);
      !vm.config.startNewClusterConfig.services.model.cbas && (delete data.cbasMemoryQuota);
      !vm.config.startNewClusterConfig.services.model.eventing && (delete data.eventingMemoryQuota);
      return addErrorHandler(mnSettingsClusterService.postPoolsDefault(data, false, newClusterState.clusterName), "postMemory");
    }
    function validateIndexSettings() {
      return mnPromiseHelper(vm, mnSettingsClusterService.postIndexSettings(vm.config.startNewClusterConfig.indexSettings))
        .catchErrors('postIndexSettingsErrors')
        .getPromise();
    }
    function postServices() {
      return addErrorHandler(mnServersService.setupServices({
        services: mnHelper.checkboxesToList(vm.config.startNewClusterConfig.services.model).join(',')
      }), "setupServices");
    }
    function postQuerySettings() {
      return addErrorHandler(mnClusterConfigurationService.postQuerySettings({
        queryTmpSpaceDir: vm.querySettings.queryTmpSpaceDir,
        queryTmpSpaceSize: vm.querySettings.queryTmpSpaceSize
      }), "postQuerySettings");
    }
    function postDiskStorage() {
      return addErrorHandler(mnClusterConfigurationService.postDiskStorage({
        path: vm.config.dbPath,
        index_path: vm.config.indexPath
      }), "postDiskStorage");
    }
    function postJoinCluster() {
      var data = _.clone(vm.joinClusterConfig.clusterMember);
      data.services = mnHelper.checkboxesToList(vm.joinClusterConfig.services.model).join(',');
      return addErrorHandler(mnClusterConfigurationService.postJoinCluster(data), "postJoinCluster");
    }
    function postStats() {
      var user = mnWizardService.getTermsAndConditionsState();
      var promise = mnClusterConfigurationService.postStats(user, vm.sendStats);

      return mnPromiseHelper(vm, promise)
        .catchGlobalErrors()
        .getPromise();
    }
    function doStartNewCluster() {
      var newClusterParams = vm.config.startNewClusterConfig;
      var hadServicesString = vm.config.selfConfig.services.sort().join("");
      var hasServicesString = mnHelper.checkboxesToList(newClusterParams.services.model).sort().join("");
      if (hadServicesString === hasServicesString) {
        return postMemoryQuota().then(postStats).then(goNext);
      } else {
        var hadIndexService = hadServicesString.indexOf("index") > -1;
        var hasIndexService = hasServicesString.indexOf("index") > -1;
        if (hadIndexService && !hasIndexService) {
          return postServices().then(function () {
            return postMemoryQuota().then(postStats).then(goNext);
          });
        } else {
          return postMemoryQuota().then(function () {
            return postServices().then(postStats).then(goNext);
          });
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
      delete vm.postQuerySettingsErrors;

      var promise = $q.all([
        postDiskStorage(),
        postQuerySettings()
      ]).then(function () {
        return addErrorHandler(mnClusterConfigurationService.postHostname(vm.config.hostname), "postHostname");
      }).then(function () {
        if (mnWizardService.getState().isNewCluster) {
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
              return $state.go('app.admin.overview').then(function () {
                $rootScope.$broadcast("maybeShowMemoryQuotaDialog", vm.joinClusterConfig.services.model);
                mnAlertsService.formatAndSetAlerts('This server has been associated with the cluster and will join on the next rebalance operation.', 'success');
              });
            });
          });
        }
      });

      mnPromiseHelper(vm, promise)
        .showGlobalSpinner();
    };
  }
})();
