angular.module('mnWizard').controller('mnWizardStep1Controller',
  function ($scope, $state, $q, mnWizardStep1Service, mnSettingsClusterService, mnAuthService, pools, mnHelper, mnServersService, mnPools, mnPoolDefault, mnAlertsService, mnMemoryQuotaService, mnPromiseHelper) {

    mnPromiseHelper($scope, mnWizardStep1Service.getSelfConfig())
      .cancelOnScopeDestroy()
      .onSuccess(function (selfConfig) {
        $scope.selfConfig = selfConfig;
        $scope.startNewClusterConfig = {
          maxMemorySize: selfConfig.ramMaxMegs,
          totalMemorySize: selfConfig.ramTotalSize,
          memoryQuota: selfConfig.memoryQuota,
          services: {
            disabled: {kv: true, index: false, n1ql: false},
            model: {kv: true, index: true, n1ql: true}
          },
          isServicesControllsAvailable: true,
          showKVMemoryQuota: true,
          showIndexMemoryQuota: true,
          indexMemoryQuota: selfConfig.indexMemoryQuota,
          minMemorySize: 256
        };
        $scope.hostname = selfConfig.hostname;
        $scope.dbPath = selfConfig.storage.hdd[0].path;
        $scope.indexPath = selfConfig.storage.hdd[0].index_path;
        $scope.onDbPathChange();
        $scope.onIndexPathChange();
      });

    $scope.joinClusterConfig = mnWizardStep1Service.getJoinClusterConfig();
    $scope.joinCluster = 'no';
    $scope.isEnterprise = pools.isEnterprise;

    $scope.$watch('startNewClusterConfig.memoryQuota', mnWizardStep1Service.setDynamicRamQuota);

    $scope.onDbPathChange = function () {
      $scope.dbPathTotal = mnWizardStep1Service.lookup($scope.dbPath, $scope.selfConfig.preprocessedAvailableStorage);
    };
    $scope.onIndexPathChange = function () {
      $scope.indexPathTotal = mnWizardStep1Service.lookup($scope.indexPath, $scope.selfConfig.preprocessedAvailableStorage);
    };

    $scope.isJoinCluster = function (value) {
      return $scope.joinCluster === value;
    };

    function goNext() {
      $state.go('app.wizard.step2');
    }

    function addErrorHandler(query, name) {
      return mnPromiseHelper($scope, query).catchErrors(name + 'Errors').getPromise();
    }
    function postMemoryQuota() {
      return addErrorHandler(mnSettingsClusterService.postPoolsDefault($scope.startNewClusterConfig), "postMemory");
    }
    function postServices() {
      return addErrorHandler(mnServersService.setupServices({
        services: mnHelper.checkboxesToList($scope.startNewClusterConfig.services.model).join(',')
      }), "setupServices");
    }
    function postDiskStorage() {
      return addErrorHandler(mnWizardStep1Service.postDiskStorage({
        path: $scope.dbPath,
        index_path: $scope.indexPath
      }), "postDiskStorage");
    }
    function postJoinCluster() {
      var data = _.clone($scope.joinClusterConfig.clusterMember);
      data.services = mnHelper.checkboxesToList($scope.joinClusterConfig.services.model).join(',');
      return addErrorHandler(mnWizardStep1Service.postJoinCluster(data), "postJoinCluster");
    }

    $scope.onSubmit = function (e) {
      if ($scope.viewLoading) {
        return;
      }

      var promise = postDiskStorage().then(function () {
        return addErrorHandler(mnWizardStep1Service.postHostname($scope.hostname), "postHostname");
      }).then(function () {
        if ($scope.isJoinCluster('no')) {
          var newClusterParams = $scope.startNewClusterConfig;
          var quotaIsChanged = newClusterParams.memoryQuota != $scope.selfConfig.memoryQuota || newClusterParams.indexMemoryQuota != $scope.selfConfig.indexMemoryQuota;
          var hadServicesString = $scope.selfConfig.services.sort().join("");
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
            return mnAuthService.login($scope.joinClusterConfig.clusterMember).then(function () {
              return mnPoolDefault.getFresh().then(function (poolsDefault) {
                if (mnMemoryQuotaService.isOnlyOneNodeWithService(poolsDefault.nodes, $scope.joinClusterConfig.services.model, 'index')) {
                  $state.go('app.wizard.step6');
                } else {
                  return mnPools.getFresh().then(function (pools) {
                    $state.go('app.admin.overview');
                    mnAlertsService.formatAndSetAlerts('This server has been associated with the cluster and will join on the next rebalance operation.', 'success');
                  });
                }
              });
            });
          });
        }
      });
      mnPromiseHelper($scope, promise).showErrorsSensitiveSpinner();
    };
  });