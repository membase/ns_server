angular.module('mnWizard').controller('mnWizardStep1Controller',
  function ($scope, $state, $q, mnWizardStep1Service, mnAuthService, selfConfig, pools, mnHelper, mnServersService) {
    $scope.hostname = selfConfig.hostname;

    $scope.clusterMember = {
      hostname: "127.0.0.1",
      username: "Administrator",
      password: ''
    };

    mnServersService.initializeServices($scope);

    $scope.$watch('joinCluster', function () {
      $scope.services = {kv: true};
    });

    $scope.dynamicRamQuota = selfConfig.dynamicRamQuota;
    $scope.ramTotalSize = selfConfig.ramTotalSize;
    $scope.ramMaxMegs = selfConfig.ramMaxMegs;
    $scope.joinCluster = 'no';

    $scope.dbPath = selfConfig.storage.hdd[0].path;
    $scope.indexPath = selfConfig.storage.hdd[0].index_path;
    $scope.isEnterprise = pools.isEnterprise;

    $scope.$watch('dynamicRamQuota', mnWizardStep1Service.setDynamicRamQuota);

    $scope.$watch('dbPath', function (pathValue) {
      $scope.dbPathTotal = mnWizardStep1Service.lookup(pathValue, selfConfig.preprocessedAvailableStorage);
    });
    $scope.$watch('indexPath', function (pathValue) {
      $scope.indexPathTotal = mnWizardStep1Service.lookup(pathValue, selfConfig.preprocessedAvailableStorage);
    });

    $scope.isJoinCluster = function (value) {
      return $scope.joinCluster === value;
    }

    function login() {
      return mnAuthService.manualLogin($scope.clusterMember);
    }
    function goNext() {
      $state.go('app.wizard.step2');
    }
    function makeRequestWithErrorsHandler(method, data) {
      return mnHelper.rejectReasonToScopeApplyer($scope, method + 'Errors', mnWizardStep1Service[method](data));
    }

    $scope.onSubmit = function (e) {
      if ($scope.viewLoading) {
        return;
      }
      var isJoinCluster = $scope.isJoinCluster('ok');
      if (isJoinCluster) {
        $scope.joinClusterForm.$setValidity('services', !!mnHelper.checkboxesToList($scope.services).length);
      }
      if ($scope.joinClusterForm.$invalid) {
        return;
      }
      var promise = $q.all([
        makeRequestWithErrorsHandler('postDiskStorage', {path: $scope.dbPath, index_path: $scope.indexPath}),
        makeRequestWithErrorsHandler('postHostname', $scope.hostname)
      ]).then(function () {
        var services = mnHelper.checkboxesToList($scope.services);
        if (!isJoinCluster) {
          return $q.all([
            mnHelper.rejectReasonToScopeApplyer($scope, 'setupServicesErrors', mnServersService.setupServices({services: services.join(',')})),
            makeRequestWithErrorsHandler('postMemory', $scope.dynamicRamQuota).then(goNext)
          ]);
        } else {
          var data = _.clone($scope.clusterMember);
          data.services = services.join(',');
          return makeRequestWithErrorsHandler('postJoinCluster', data).then(login).then(mnHelper.reloadApp);
        }
      });
      mnHelper.handleSpinner($scope, promise);
    };
  });