angular.module('mnWizard').controller('mnWizardStep1Controller',
  function ($scope, $state, $window, $q, mnWizardStep1Service, mnAuthService, selfConfig, pools, mnHelper) {
    $scope.hostname = selfConfig.hostname;

    $scope.clusterMember = {
      hostname: "127.0.0.1",
      username: "Administrator",
      password: ''
    };

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
      var promise = $q.all([
        makeRequestWithErrorsHandler('postDiskStorage', {path: $scope.dbPath, index_path: $scope.indexPath}),
        makeRequestWithErrorsHandler('postHostname', $scope.hostname)
      ]).then(function () {
        if ($scope.isJoinCluster('ok')) {
          return makeRequestWithErrorsHandler('postJoinCluster', $scope.clusterMember).then(login).then(function () {$window.location.reload();});
        } else {
          return makeRequestWithErrorsHandler('postMemory', $scope.dynamicRamQuota).then(goNext);
        }
      });
      mnHelper.handleSpinner($scope, promise);
    };
  });