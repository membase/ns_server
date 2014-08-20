angular.module('mnAuthService').factory('mnAuthService', function ($rootScope, $http, $location, $state) {
  var mnAuthService = {};
  mnAuthService.model = {};

  $rootScope.$on('$stateChangeStart', function (event, current) {
    if (current.authenticate && !mnAuthService.model.isAuth) {
      $state.transitionTo(mnAuthService.model.initialized ? 'auth' : 'wizard.welcome');
      event.preventDefault();
    }
    if (current.name == 'auth' && mnAuthService.model.isAuth) {
      $state.transitionTo(mnAuthService.model.initialized ? 'app.overview' : 'wizard.welcome');
      event.preventDefault();
    }
  });

  mnAuthService.manualLogin = function (user) {
    user = user || {};

    return $http({
      method: 'POST',
      url: '/uilogin',
      data: 'user=' + user.username + '&password=' + user.password,
      headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
    }).success(getPools);
  }

  mnAuthService.manualLogout = function () {
    return $http({
      method: 'POST',
      url: "/uilogout"
    }).success(function () {
      mnAuthService.model.isAuth = false;
      $state.transitionTo('auth');
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

    $state.transitionTo(mnAuthService.model.initialized ? mnAuthService.model.isAuth ? 'app.overview' : 'auth' : 'wizard.welcome');
  }
  function getPools() {
    return $http({method: 'GET', url: '/pools', requestType: 'json'}).success(onPools);
  }

  mnAuthService.entryPoint = getPools;

  return mnAuthService;
});


