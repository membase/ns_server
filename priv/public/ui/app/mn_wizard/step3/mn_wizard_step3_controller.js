(function () {
  "use strict";

  angular
    .module('mnWizard')
    .controller('mnWizardStep3Controller', mnWizardStep3Controller);

  function mnWizardStep3Controller($scope, $state, mnWizardStep3Service, mnPromiseHelper, mnBucketsDetailsDialogService) {
    var vm = this;

    vm.validationKeeper = {};
    vm.onSubmit = onSubmit;

    activate();

    function activate() {
      mnPromiseHelper(vm, mnWizardStep3Service.getWizardBucketConf())
        .applyToScope("bucketConf");
    }
    function onSubmit() {
      var params = mnBucketsDetailsDialogService.prepareBucketConfigForSaving(vm.bucketConf);
      var promise = mnWizardStep3Service.postBuckets(params, vm.bucketConf.uri);
      mnPromiseHelper(vm, promise)
        .showErrorsSensitiveSpinner()
        .getPromise()
        .then(function (result) {
          !result.data && $state.go('app.wizard.step4');
        });
    }
  }
})();
