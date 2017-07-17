(function () {
  "use strict";

  angular.module('mnAuth', [
    'mnAuthService',
    'ui.router',
    'mnAboutDialog',
    'mnAutocompleteOff'
  ]).config(mnAuthConfig);

  function mnAuthConfig($stateProvider, $httpProvider, $urlRouterProvider) {
    $httpProvider.interceptors.push(['$q', '$injector', interceptorOf401]);
    $stateProvider.state('app.auth', {
      url: "/auth",
      templateUrl: 'app/mn_auth/mn_auth.html',
      controller: 'mnAuthController as authCtl'
    });

    function interceptorOf401($q, $injector) {
      return {
        responseError: function (rejection) {
          if (rejection.status === 401 &&
              rejection.config.url !== "/pools" &&
              $injector.get('$state').includes('app.admin') &&
              !rejection.config.headers["ignore-401"]) {
            $injector.get('mnAuthService').logout();
          }
          return $q.reject(rejection);
        }
      };
    }
  }
})();
