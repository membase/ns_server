(function () {
  "use strict";

  angular.module('mnAuthService', [
    'mnPools',
    'ui.router',
    'mnPendingQueryKeeper',
    'mnPermissions'
  ]).factory('mnAuthService', mnAuthServiceFactory);

  function mnAuthServiceFactory($http, $state, mnPools, mnPendingQueryKeeper, mnPermissions, $uibModalStack) {
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
      }).then(function (resp) {
        mnPools.clearCache();
        return resp;
      });
    }
    function logout() {
      return $http({
        method: 'POST',
        url: "/uilogout"
      }).then(function () {
        $uibModalStack.dismissAll("uilogout");
        mnPools.clearCache();
        $state.go('app.auth');
        mnPendingQueryKeeper.cancelAllQueries();
        mnPermissions.clear();
      });
    }
  }
})();

