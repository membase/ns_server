(function () {
  "use strict";

  angular.module('mnAuthService', [
    'mnPools',
    'ui.router'
  ]).factory('mnAuthService', mnAuthServiceFactory);

  function mnAuthServiceFactory($http, $rootScope, $state, mnPools) {
    var mnAuthService = {
      login: login,
      logout: logout
    };

    return mnAuthService;

    function login(user) {
      user = user || {};
      return $http({
        method: 'POST',
        url: '/uilogin',
        data: {
          user: user.username,
          password: user.password
        }
      });
    }
    function logout() {
      return $http({
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

