(function () {
  "use strict";

  angular
    .module('mnAuth')
    .controller('mnAuthController', mnAuthController);

  function mnAuthController(mnAuthService, $location, $state, $urlRouter) {
    var vm = this;

    vm.loginFailed = false;
    vm.submit = submit;

    if ($state.transition.$from().includes["app.wizard"]) {
      error({status: "initialized"})
    }

    function error(resp) {
      vm.error = {};
      vm.error["_" + resp.status] = true;
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
