(function () {
  "use strict";

  angular
    .module('mnAuth')
    .controller('mnAuthController', mnAuthController);

  function mnAuthController(mnAuthService, $location, $state, mnAboutDialogService, $urlRouter) {
    var vm = this;

    vm.loginFailed = false;
    vm.submit = submit;
    vm.showAboutDialog = mnAboutDialogService.showAboutDialog;

    function error() {
      vm.loginFailed = true;
    }
    function success() {
      /* never sync to /auth URL (as user will stay on the login page) */
      if ($location.path() === "/auth") {
        $state.go('app.admin.overview');
      } else {
        $urlRouter.sync();
      }
    }
    function submit() {
      mnAuthService
        .login(vm.user)
        .then(success, error);
    }
  }
})();
