(function () {
  "use strict";

  angular.module('mnAuth', [
    'mnAuthService',
    'ui.router',
    'mnAboutDialog'
  ]).config(mnAuthConfig);

  function mnAuthConfig($stateProvider, $httpProvider, $urlRouterProvider) {
    $httpProvider.interceptors.push(['$q', '$injector', interceptorOf401]);
    $urlRouterProvider.when('', '/auth');
    $urlRouterProvider.when('/', '/auth');
    $stateProvider.state('app.auth', {
      templateUrl: 'app/mn_auth/mn_auth.html',
      controller: 'mnAuthController as authCtl'
    });

    function interceptorOf401($q, $injector) {
      return {
        responseError: function (rejection) {
          if (rejection.status === 401 && rejection.config.url !== "/pools" && $injector.get('$state').includes('app.admin')) {
            $injector.get('mnAuthService').logout();
          }
          return $q.reject(rejection);
        }
      };
    }
  }
})();
