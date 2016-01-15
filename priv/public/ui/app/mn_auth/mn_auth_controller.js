(function () {
  "use strict";

  angular
    .module('mnAuth')
    .controller('mnAuthController', mnAuthController);

  function mnAuthController($scope, mnAuthService, $state, mnPools, mnAboutDialogService) {
    var vm = this;

    vm.loginFailed = false;
    vm.submit = submit;
    vm.showAboutDialog = mnAboutDialogService.showAboutDialog;

    function error() {
      vm.loginFailed = true;
    }
    function success() {
      $state.go('app.admin.overview');
    }
    function submit() {
      mnAuthService
        .login(vm.user)
        .then(success, error);
    }
  }
})();
