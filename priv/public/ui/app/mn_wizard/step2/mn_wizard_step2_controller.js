(function () {
  "use strict";

  angular
    .module('mnWizard')
    .controller('mnWizardStep2Controller', mnWizardStep2Controller);

  function mnWizardStep2Controller($scope, mnWizardStep2Service, mnPromiseHelper, mnSettingsSampleBucketsService) {
    var vm = this;

    vm.selected = {};

    activate();

    $scope.$watch('wizardStep2Ctl.selected', mnWizardStep2Service.setSelected, true);

    function activate() {
      mnPromiseHelper(vm, mnSettingsSampleBucketsService.getSampleBuckets())
        .cancelOnScopeDestroy($scope)
        .applyToScope("sampleBuckets");
    }
  }
})();