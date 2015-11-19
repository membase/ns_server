(function () {
  "use strict";

  angular.module('mnAuthService', [
    'mnHttp',
    'mnPools',
    'ui.router'
  ]).factory('mnAuthService', mnAuthServiceFactory);

  function mnAuthServiceFactory(mnHttp, $rootScope, $state, mnPools) {
    var mnAuthService = {
      login: login,
      logout: logout
    };

    return mnAuthService;

    function login(user) {
      user = user || {};
      return mnHttp({
        method: 'POST',
        url: '/uilogin',
        data: {
          user: user.username,
          password: user.password
        }
      });
    }
    function logout() {
      return mnHttp({
        method: 'POST',
        url: "/uilogout"
      }).then(function () {
        return mnPools.getFresh().then(function () {
          $state.go('app.auth');
        });
      });
    }
  }
})();

