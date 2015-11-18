(function () {
  "use strict";

  angular.module('mnSettingsAutoCompaction', [
    'mnSettingsAutoCompactionService',
    'mnHelper',
    'mnPromiseHelper',
    'mnAutoCompactionForm',
    'mnPoolDefault'
  ]).controller('mnSettingsAutoCompactionController', mnSettingsAutoCompactionController);

  function mnSettingsAutoCompactionController($scope, mnHelper, mnPromiseHelper, mnSettingsAutoCompactionService, mnPoolDefault) {
    var vm = this;

    vm.submit = submit;
    vm.mnPoolDefault = mnPoolDefault.latestValue();

    activate();

    function activate() {
      mnPromiseHelper(vm, mnSettingsAutoCompactionService.getAutoCompaction())
        .applyToScope("autoCompactionSettings")
        .onSuccess(function () {
          $scope.$watch('mnSettingsAutoCompactionController.autoCompactionSettings', watchOnAutoCompactionSettings, true);
        });
    }
    function watchOnAutoCompactionSettings(autoCompactionSettings) {
      mnPromiseHelper(vm, mnSettingsAutoCompactionService
        .saveAutoCompaction(autoCompactionSettings, {just_validate: 1}))
          .catchErrors()
          .cancelOnScopeDestroy($scope);
    }
    function submit() {
      if (vm.viewLoading) {
        return;
      }
      mnPromiseHelper(vm, mnSettingsAutoCompactionService.saveAutoCompaction(vm.autoCompactionSettings))
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .reloadState()
        .cancelOnScopeDestroy($scope);
    }
  }
})();
