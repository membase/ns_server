angular.module('mnWizard').controller('mnWizardStep3Controller',
  function ($scope, $state, mnWizardStep3Service, bucketConf, mnHelper) {
    $scope.bucketConf = bucketConf;

    $scope.onSubmit = function () {
      var promise = mnWizardStep3Service.postBuckets($scope.bucketConf);
      mnHelper
        .promiseHelper($scope, promise)
        .showErrorsSensitiveSpinner()
        .getPromise()
        .then(function (result) {
          !result.data && $state.go('app.wizard.step4');
        });
    };
  });