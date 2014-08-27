angular.module('mnWizard').controller('mnWizardStep1Controller',
  function ($scope, $state, mnWizardStep1Service, mnAuthService, mnWizardStep1JoinClusterService, mnWizardStep1DiskStorageService) {
    $scope.mnWizardStep1ServiceModel = mnWizardStep1Service.model;

    $scope.onSubmit = function (e) {
      if ($scope.stepSubmited) {
        return;
      }
      $scope.stepSubmited = true;
      makeRequest(mnWizardStep1DiskStorageService, 'postDiskStorage').success(doPostHostName);
    }

    $scope.$watch(function () {
      return !$scope.mnWizardStep1ServiceModel.nodeConfig || $scope.stepSubmited;
    }, function (isViewLoading) {
      $scope.viewLoading = isViewLoading;
    });

    mnWizardStep1Service.getSelfConfig();

    function doPostHostName() {
      var nextAction = mnWizardStep1JoinClusterService.model.joinCluster === 'ok' ? doPostJoinCluster : doPostMemory;
      makeRequest(mnWizardStep1Service, 'postHostname', postHostnameErrorExtr).success(nextAction);
    }
    function doPostJoinCluster() {
      makeRequest(mnWizardStep1JoinClusterService, 'postJoinCluster').success(doLogin);
    }
    function doPostMemory() {
      makeRequest(mnWizardStep1JoinClusterService, 'postMemory', postMemoryErrorExtr).success(goToNextPage);
    }
    function goToNextPage() {
      $state.transitionTo('wizard.step2');
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


    function makeRequest(module, method, errorExtractor) {
      return module[method]().success(function () {
        $scope[method + 'Errors'] = false;
      }).error(function (errors) {
        $scope[method + 'Errors'] = errorExtractor ? errorExtractor(errors) : errors;
        stopSpinner();
      });
    }
  });