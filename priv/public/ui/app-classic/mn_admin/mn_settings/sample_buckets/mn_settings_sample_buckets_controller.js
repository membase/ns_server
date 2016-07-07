(function () {
  "use strict";

  angular
    .module("mnSettingsSampleBuckets", ["mnSettingsSampleBucketsService", "mnPromiseHelper"])
    .controller("mnSettingsSampleBucketsController", mnSettingsSampleBucketsController);

  function mnSettingsSampleBucketsController($scope, mnSettingsSampleBucketsService, mnPromiseHelper) {
    var vm = this;
    vm.selected = {};
    vm.isCreateButtonDisabled = isCreateButtonDisabled;
    vm.installSampleBuckets = installSampleBuckets;

    activate();

    function activate() {
      $scope.$watch("settingsSampleBucketsCtl.selected", function (selected) {
        mnPromiseHelper(vm, mnSettingsSampleBucketsService.getSampleBucketsState(selected))
          .showSpinner()
          .applyToScope("state");
      }, true);
    }

    function installSampleBuckets() {
      mnPromiseHelper(vm, mnSettingsSampleBucketsService.installSampleBuckets(vm.selected))
        .showErrorsSensitiveSpinner()
        .reloadState();
    }

    function isCreateButtonDisabled() {
      return vm.viewLoading || vm.state &&
             (_.chain(vm.state.warnings).values().some().value() ||
             !vm.state.available.length) ||
             !_.keys(_.pick(vm.selected, _.identity)).length;
    }

  }
})();
