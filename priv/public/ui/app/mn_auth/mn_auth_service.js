(function () {
  "use strict";

  angular.module('mnAuthService', [
    'mnPools',
    'ui.router',
    'mnPendingQueryKeeper',
    'mnPermissions'
  ]).factory('mnAuthService', mnAuthServiceFactory);

  function mnAuthServiceFactory($http, $state, mnPools, $rootScope, mnPendingQueryKeeper, mnPermissions, $uibModalStack, $window, $q, $cacheFactory) {
    var mnAuthService = {
      login: login,
      logout: logout,
      whoami: whoami
    };

    return mnAuthService;

    function whoami() {
      return $http({
        method: 'GET',
        cache: true,
        url: '/whoami'
      }).then(function (resp) {
        return resp.data;
      });
    }

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
        return mnPools.get().then(function (cachedPools) {
          mnPools.clearCache();
          return mnPools.get().then(function (newPools) {
            if (cachedPools.implementationVersion !== newPools.implementationVersion) {
              return $q.reject({status: 410});
            } else {
              return resp;
            }
          });
        }).then(function (resp) {
          localStorage.setItem("mnLogIn",
                               Number(localStorage.getItem("mnLogIn") || "0") + 1);
          return resp;
        })
      });
    }
    function logout() {
      $uibModalStack.dismissAll("uilogout");
      return $http({
        method: 'POST',
        url: "/uilogout"
      }).then(function () {
        mnPools.clearCache();
        $state.go('app.auth').then(function () {
          delete $rootScope.poolDefault;
          delete $rootScope.pools;
          mnPermissions.clear();
        });
        $cacheFactory.get('$http').remove('/whoami');
        $window.localStorage.removeItem('mn_xdcr_regex');
        $window.localStorage.removeItem('mn_xdcr_testKeys');
        mnPendingQueryKeeper.cancelAllQueries();
      });
    }
  }
})();
