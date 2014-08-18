angular.module('wizard')
  .controller('wizard.step1.Controller',
    ['$scope', 'wizard.step1.service', '$state', 'auth.service', 'wizard.step1.joinCluster.service', 'wizard.step1.diskStorage.service',
      function ($scope, step1Service, $state, authService, joinClusterService, diskStorageService) {
        $scope.spinner = true;
        $scope.modelStep1Service = step1Service.model;

        $scope.onSubmit = function onSubmit(e) {
          if ($scope.spinner) {
            return;
          }
          $scope.spinner = true;
          makeRequest(diskStorageService, 'postDiskStorage').success(doPostHostName);
        }

        step1Service.getSelfConfig().success(stopSpinner).error(stopSpinner);

        function doPostHostName() {
          var nextAction = joinClusterService.model.joinCluster === 'ok' ? doPostJoinCluster : doPostMemory;
          makeRequest(step1Service, 'postHostname', postHostnameErrorExtr).success(nextAction);
        }
        function doPostJoinCluster() {
          makeRequest(joinClusterService, 'postJoinCluster').success(doLogin);
        }
        function doPostMemory() {
          makeRequest(joinClusterService, 'postMemory', postMemoryErrorExtr).success(goToNextPage);
        }
        function goToNextPage() {
          $state.transitionTo('wizard.step2');
          joinClusterService.resetClusterMember();
        }
        function doLogin() {
          authService.manualLogin({
            username: joinClusterService.model.clusterMember.user,
            password: joinClusterService.model.clusterMember.password
          }).success(joinClusterService.resetClusterMember)

        }
        function stopSpinner() {
          $scope.spinner = false;
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
      }]);