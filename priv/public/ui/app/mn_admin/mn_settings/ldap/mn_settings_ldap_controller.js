(function () {
  "use strict";

  angular
    .module('mnSettingsLdap', [
      "mnSettingsLdapService",
      "mnPromiseHelper"
    ])
    .controller('mnSettingsLdapController', mnSettingsLdapController)
    .filter("formatRoleMessage", formatRoleMessageFilter);

    function mnSettingsLdapController($scope, mnSettingsLdapService, mnPromiseHelper, mnPoolDefault) {
      var vm = this;

      vm.test = {};
      vm.isValidateButtonDisabled = isValidateButtonDisabled;
      vm.isFullAdminsDisabled = isFullAdminsDisabled;
      vm.isReadOnlyAdminsDisabled = isReadOnlyAdminsDisabled;
      vm.isRadioDefaultDisabled = isRadioDefaultDisabled;
      vm.isRecognizedNotViaLdap = isRecognizedNotViaLdap;
      vm.validate = validate;
      vm.save = save;
      vm.isUserFormDisabled = isUserFormDisabled;
      vm.mnPoolDefault = mnPoolDefault.latestValue();

      activate();

      function isValidateButtonDisabled() {
        return !vm.test.username || !vm.test.password || !vm.state || !vm.state.enabled || vm.mnPoolDefault.value.isROAdminCreds;
      }
      function isReadOnlyAdminsDisabled() {
        return !vm.state || !vm.state.enabled || vm.state["default"] === "roAdmins" || vm.mnPoolDefault.value.isROAdminCreds;
      }
      function isFullAdminsDisabled() {
        return !vm.state || !vm.state.enabled || vm.state["default"] === "admins" || vm.mnPoolDefault.value.isROAdminCreds;
      }
      function isRadioDefaultDisabled() {
        return !vm.state || !vm.state.enabled || vm.mnPoolDefault.value.isROAdminCreds;
      }
      function isRecognizedNotViaLdap() {
        return (vm.validateResult && vm.validateResult.role !== 'none' && vm.validateResult.source === 'builtin');
      }
      function isUserFormDisabled() {
        return (vm.state && !vm.state.enabled) || vm.mnPoolDefault.value.isROAdminCreds;
      }
      function validate() {
        if (vm.validateSpinner) {
          return;
        }
        var test = vm.test;
        vm.test = {};
        mnPromiseHelper(vm, mnSettingsLdapService.validateCredentials(test))
          .catchErrors("validateErrors")
          .showSpinner("validateSpinner")
          .applyToScope("validateResult");
      }
      function save() {
        if (vm.viewLoading) {
          return;
        }
        mnPromiseHelper(vm, mnSettingsLdapService.postSaslauthdAuth(vm.state))
          .showErrorsSensitiveSpinner()
          .catchErrors()
          .reloadState();
      }
      function activate() {
        mnPromiseHelper(vm, mnSettingsLdapService.getSaslauthdAuth())
          .applyToScope("state");
      }
    }
    function formatRoleMessageFilter() {
      return function (role) {
        switch (role) {
          case "none": return "no";
          case "roAdmin": return "\"Read-Only Admin\"";
          case "fullAdmin": return "\"Full Admin\"";
        }
      }
    }

})();

