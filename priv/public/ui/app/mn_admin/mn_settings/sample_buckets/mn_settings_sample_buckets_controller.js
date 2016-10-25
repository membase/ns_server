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
    function getState(selected) {
      return mnPromiseHelper(vm, mnSettingsSampleBucketsService.getSampleBucketsState(selected || vm.selected)).applyToScope("state");
    }
    function activate() {
      getState().showSpinner();
      $scope.$watch("settingsSampleBucketsCtl.selected", function (value, oldValue) {
        if (value !== oldValue) {
          getState(value);
        }
      }, true);
    }

    function installSampleBuckets() {
      mnPromiseHelper(vm, mnSettingsSampleBucketsService.installSampleBuckets(vm.selected))
        .showGlobalSpinner()
        .catchGlobalErrors()
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
