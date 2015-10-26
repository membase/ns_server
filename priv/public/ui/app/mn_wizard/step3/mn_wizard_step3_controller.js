angular.module('mnWizard').controller('mnWizardStep3Controller',
  function ($scope, $state, mnWizardStep3Service, mnPromiseHelper) {
    $scope.validationKeeper = {};

    mnPromiseHelper($scope, mnWizardStep3Service.getWizardBucketConf())
      .applyToScope("bucketConf")
      .cancelOnScopeDestroy();

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