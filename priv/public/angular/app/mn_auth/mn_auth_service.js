angular.module('mnAuthService').factory('mnAuthService',
  function ($rootScope, $http, $state, $urlRouter) {

  var mnAuthService = {};

  mnAuthService.model = {};

  $rootScope.$on('$stateChangeStart', function (event, current) {
    if (mnAuthService.model.initialized === undefined) {
      return event.preventDefault();
    }

    if (current.authenticate && !mnAuthService.model.isAuth) {
      event.preventDefault();
      $state.go('auth');
    }

    if (current.name == 'auth') {
      if (mnAuthService.model.initialized) {
        if (mnAuthService.model.isAuth) {
          event.preventDefault();
          $state.go('admin.overview');
        }
      } else {
        event.preventDefault();
        $state.go('wizard.welcome');
      }
    }
  });

  mnAuthService.manualLogin = function (user) {
    user = user || {};

    return $http({
      method: 'POST',
      url: '/uilogin',
      data: _.serializeData({user: user.username, password: user.password}),
      headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
    }).success(function () {
      getPools().success(function () {
        $state.go('admin.overview');
      })
    });
  }

  mnAuthService.manualLogout = function () {
    return $http({
      method: 'POST',
      url: "/uilogout"
    }).success(function () {
      mnAuthService.model.isAuth = false;
      $state.go('auth');
    });
  }

  function onPools(pools) {
    if (!pools) {
      return;
    }

    mnAuthService.model.initialized = !!pools.pools.length;
    mnAuthService.model.defaultPoolUri = mnAuthService.model.initialized && pools.pools[0].uri;
    mnAuthService.model.isAuth = pools.isAdminCreds && mnAuthService.model.initialized;
    mnAuthService.model.version = pools.implementationVersion;
    mnAuthService.model.isEnterprise = pools.isEnterprise;

    $urlRouter.sync();
  }
  function getPools() {
    return $http({method: 'GET', url: '/pools', requestType: 'json'})
      .success(onPools)
      .error(function (error, status) {
        if (status === 401) {
          mnAuthService.model.initialized = true;
          $urlRouter.sync();
        }
      });
  }

  mnAuthService.entryPoint = getPools;

  return mnAuthService;
});


