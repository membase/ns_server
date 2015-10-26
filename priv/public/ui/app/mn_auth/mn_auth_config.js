angular.module('mnAuth', [
  'mnAuthService',
  'ui.router'
]).config( function ($stateProvider, $httpProvider, $urlRouterProvider) {
  $httpProvider.interceptors.push(['$q', '$injector', function ($q, $injector) {
    return {
      responseError: function (rejection) {
        if (rejection.status === 401 && rejection.config.url !== "/pools") {
          var mnPools = $injector.get('mnPools');
          mnPools.get().then(function (pools) {
            if (pools.isAuthenticated) {
              var mnAuthService = $injector.get('mnAuthService');
              mnAuthService.logout();
            }
          });
        }
        return $q.reject(rejection);
      }
    }
  }]);

  $urlRouterProvider.when('', '/auth');
  $urlRouterProvider.when('/', '/auth');

  $stateProvider.state('app.auth', {
    templateUrl: 'app/mn_auth/mn_auth.html',
    controller: 'mnAuthController'
  });
});