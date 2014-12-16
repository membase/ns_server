angular.module('mnWizard').controller('mnWizardStep3Controller',
  function ($scope, $state, mnWizardStep3Service, bucketConf, mnHelper) {
    $scope.guageConfig = {};
    $scope.focusMe = true;
    $scope.replicaNumberEnabled = true;
    $scope.bucketConf = bucketConf;

    $scope.onSubmit = function () {
      var promise = mnWizardStep3Service.postBuckets({data: $scope.bucketConf});
      mnHelper.handleSpinner($scope, promise, null, true);
      promise.then(function (result) {
        if (!result) {
          $state.go('app.wizard.step4');
        } else {
          $scope.validationResult = result;
        }
      });
    };

    $scope.$watch('replicaNumberEnabled', function (isEnabled) {
      if (!isEnabled) {
        $scope.bucketConf.replicaNumber = 0;
        $scope.bucketConf.replicaIndex = 0;
      } else {
        $scope.bucketConf.replicaNumber = 1;
      }
    });

    $scope.$watch('bucketConf', function () {
      mnWizardStep3Service.postBuckets({
        data: $scope.bucketConf,
        params: {
          just_validate: 1
        }
      }).then(function (result) {
        $scope.validationResult = result;
      });
    }, true);
  });