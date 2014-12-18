angular.module('mnWizard').controller('mnWizardStep3Controller',
  function ($scope, $state, mnWizardStep3Service, bucketConf, mnHelper) {
    $scope.bucketConf = bucketConf;

    $scope.onSubmit = function () {
      var promise = mnWizardStep3Service.postBuckets($scope.bucketConf);
      mnHelper.handleSpinner($scope, promise, null, true);
      promise.then(function (result) {
        if (!result.data) {
          $state.go('app.wizard.step4');
        } else {
          $scope.validationResult = result;
        }
      });
    };
  });