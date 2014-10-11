angular.module('mnWizard').controller('mnWizardStep1Controller',
  function ($scope, $state, mnWizardStep1Service, mnAuthService, mnWizardStep1JoinClusterService, mnWizardStep1DiskStorageService) {
    $scope.mnWizardStep1ServiceModel = mnWizardStep1Service.model;

    $scope.onSubmit = function (e) {
      if ($scope.stepSubmited) {
        return;
      }
      $scope.stepSubmited = true;
      makeRequest(mnWizardStep1DiskStorageService, 'postDiskStorage', undefined, {
        path: mnWizardStep1DiskStorageService.model.dbPath,
        index_path: mnWizardStep1DiskStorageService.model.indexPath
      }).success(doPostHostName);
    }

    $scope.$watch(function () {
      return !$scope.mnWizardStep1ServiceModel.nodeConfig || $scope.stepSubmited;
    }, function (isViewLoading) {
      $scope.viewLoading = isViewLoading;
    });

    mnWizardStep1Service.getSelfConfig();

    function doPostHostName() {
      var nextAction = mnWizardStep1JoinClusterService.model.joinCluster === 'ok' ? doPostJoinCluster : doPostMemory;
      makeRequest(mnWizardStep1Service, 'postHostname', postHostnameErrorExtr, {hostname: mnWizardStep1Service.model.hostname}).success(nextAction);
    }
    function doPostJoinCluster() {
      makeRequest(mnWizardStep1JoinClusterService, 'postJoinCluster', undefined, mnWizardStep1JoinClusterService.model.clusterMember).success(doLogin);
    }
    function doPostMemory() {
      makeRequest(mnWizardStep1JoinClusterService, 'postMemory', postMemoryErrorExtr, {memoryQuota: mnWizardStep1JoinClusterService.model.dynamicRamQuota}).success(goToNextPage);
    }
    function goToNextPage() {
      $state.go('wizard.step2');
      mnWizardStep1JoinClusterService.resetClusterMember();
    }
    function doLogin() {
      mnAuthService.manualLogin({
        username: mnWizardStep1JoinClusterService.model.clusterMember.user,
        password: mnWizardStep1JoinClusterService.model.clusterMember.password
      }).success(mnWizardStep1JoinClusterService.resetClusterMember)

    }
    function stopSpinner() {
      $scope.stepSubmited = false;
    }
    function postMemoryErrorExtr(errors) {
      return errors.errors.memoryQuota;
    }
    function postHostnameErrorExtr(errors) {
      return errors[0];
    }


    function makeRequest(module, method, errorExtractor, data) {
      return module[method]({data: data}).success(function () {
        $scope[method + 'Errors'] = false;
      }).error(function (errors) {
        $scope[method + 'Errors'] = errorExtractor ? errorExtractor(errors) : errors;
        stopSpinner();
      });
    }
  });