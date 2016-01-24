(function () {
  "use strict";

  angular
    .module('mnLdap', [
      "mnLdapService",
      "mnPromiseHelper"
    ])
    .controller('mnLdapController', mnLdapController)
    .filter("formatRoleMessage", formatRoleMessageFilter);

    function mnLdapController($scope, mnLdapService, mnPromiseHelper) {
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

      activate();

      function isValidateButtonDisabled() {
        return !vm.test.username || !vm.test.password || !vm.state || !vm.state.enabled;
      }
      function isReadOnlyAdminsDisabled() {
        return !vm.state || !vm.state.enabled || vm.state["default"] === "roAdmins";
      }
      function isFullAdminsDisabled() {
        return !vm.state || !vm.state.enabled || vm.state["default"] === "admins";
      }
      function isRadioDefaultDisabled() {
        return !vm.state || !vm.state.enabled;
      }
      function isRecognizedNotViaLdap() {
        return (vm.validateResult && vm.validateResult.role !== 'none' && vm.validateResult.source === 'builtin');
      }
      function isUserFormDisabled() {
        return (vm.state && !vm.state.enabled);
      }
      function validate() {
        if (vm.validateSpinner) {
          return;
        }
        var test = vm.test;
        vm.test = {};
        mnPromiseHelper(vm, mnLdapService.validateCredentials(test))
          .catchErrors("validateErrors")
          .showSpinner("validateSpinner")
          .applyToScope("validateResult");
      }
      function save() {
        if (vm.viewLoading) {
          return;
        }
        mnPromiseHelper(vm, mnLdapService.postSaslauthdAuth(vm.state))
          .showErrorsSensitiveSpinner()
          .catchErrors()
          .reloadState();
      }
      function activate() {
        mnPromiseHelper(vm, mnLdapService.getSaslauthdAuth())
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

