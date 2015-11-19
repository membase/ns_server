(function () {
  "use strict";

  angular
    .module('mnAuth')
    .controller('mnAuthController', mnAuthController);

  function mnAuthController($scope, mnAuthService, $state, mnPools) {
    var vm = this;

    vm.loginFailed = false;
    vm.submit = submit;

    function error() {
      vm.loginFailed = true;
    }
    function success() {
      return mnPools.getFresh().then(function () {
        $state.go('app.admin.overview');
      });
    }
    function submit() {
      mnAuthService
        .login(vm.user)
        .then(success, error);
    }
  }
})();
