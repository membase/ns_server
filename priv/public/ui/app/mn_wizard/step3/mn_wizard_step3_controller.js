(function () {
  "use strict";

  angular
    .module('mnWizard')
    .controller('mnWizardStep3Controller', mnWizardStep3Controller);

  function mnWizardStep3Controller($scope, $state, mnWizardStep3Service, mnPromiseHelper) {
    var vm = this;

    vm.validationKeeper = {};
    vm.onSubmit = onSubmit;

    activate();

    function activate() {
      mnPromiseHelper(vm, mnWizardStep3Service.getWizardBucketConf())
        .applyToScope("bucketConf");
    }
    function onSubmit() {
      var promise = mnWizardStep3Service.postBuckets(vm.bucketConf);
      mnPromiseHelper(vm, promise)
        .showErrorsSensitiveSpinner()
        .getPromise()
        .then(function (result) {
          !result.data && $state.go('app.wizard.step4');
        });
    }
  }
})();
