(function () {
  "use strict";

  angular
    .module('mnWizard')
    .controller('mnWizardStep3Controller', mnWizardStep3Controller);

  function mnWizardStep3Controller($scope, $state, mnWizardStep3Service, mnPromiseHelper, mnBucketsDetailsDialogService, pools) {
    var vm = this;
    vm.pools = pools;

    vm.validationKeeper = {};
    vm.onSubmit = onSubmit;

    activate();

    function activate() {
      mnPromiseHelper(vm, mnWizardStep3Service.getWizardBucketConf())
        .applyToScope("bucketConf");
    }
    function onSubmit() {
      var params = mnBucketsDetailsDialogService.prepareBucketConfigForSaving(vm.bucketConf, null, null, pools);
      var promise = mnWizardStep3Service
          .postBuckets(params, vm.bucketConf.uri)
          .then(function (result) {
            return !result.data && $state.go('app.wizard.step4');
          });
      mnPromiseHelper(vm, promise).showGlobalSpinner();
    }
  }
})();
