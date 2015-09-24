angular.module('mnWizard').controller('mnWizardStep3Controller',
  function ($scope, $state, mnWizardStep3Service, bucketConf, mnPromiseHelper) {
    $scope.bucketConf = bucketConf;
    $scope.validationKeeper = {};

    $scope.onSubmit = function () {
      var promise = mnWizardStep3Service.postBuckets($scope.bucketConf);
      mnPromiseHelper($scope, promise)
        .showErrorsSensitiveSpinner()
        .getPromise()
        .then(function (result) {
          !result.data && $state.go('app.wizard.step4');
        });
    };
  });