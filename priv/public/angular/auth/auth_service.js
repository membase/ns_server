angular.module('auth.service', ['ui.router']).config(function ($httpProvider, $stateProvider) {
  $httpProvider.defaults.headers.common['invalid-auth-response'] = 'on';
  $httpProvider.defaults.headers.common['Cache-Control'] = 'no-cache';
  $httpProvider.defaults.headers.common['Pragma'] = 'no-cache';
  $httpProvider.responseInterceptors.push(['$q', '$location', logsOutUserOn401]);

  $stateProvider.state('auth', {
    url: '/auth',
    templateUrl: '/angular/auth/auth.html',
    controller: 'auth.Controller',
    authenticate: false
  });

  function logsOutUserOn401($q, $location) {
    return function (promise) {
      return promise.then(success, error);
    };
    function success(response) {
      return response;
    };
    function error(response) {
      response.status === 401 && $location.path('/auth');
      return $q.reject(response);
    };
  }
}).factory('auth.service',
  ['$rootScope', '$http', '$location', '$state',
    function ($rootScope, $http, $location, $state) {
      var scope = {};
      scope.model = {};

      $rootScope.$on('$stateChangeStart', function (event, current) {
        if (current.authenticate && !scope.model.isAuth) {
          $state.transitionTo(scope.model.initialized ? 'auth' : 'wizard.welcome');
          event.preventDefault();
        }
        if (current.name == 'auth' && scope.model.isAuth) {
          $state.transitionTo(scope.model.initialized ? 'app.overview' : 'wizard.welcome');
          event.preventDefault();
        }
      });

      scope.manualLogin = function manualLogin(user) {
        user = user || {};

        return $http({
          method: 'POST',
          url: '/uilogin',
          data: 'user=' + user.name + '&password=' + user.password,
          headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
        }).success(getPools);
      }

      scope.manualLogout = function manualLogout() {
        return $http({
          method: 'POST',
          url: "/uilogout"
        }).success(function () {
          scope.model.isAuth = false;
          $state.transitionTo('auth');
        });
      }

      function onPools(pools) {
        if (!pools) {
          return;
        }
        scope.model.initialized = !!pools.pools.length;
        scope.model.defaultPoolUri = scope.model.initialized && pools.pools[0].uri;
        scope.model.isAuth = pools.isAdminCreds && scope.model.initialized;
        scope.model.version = pools.implementationVersion;
        scope.model.isEnterprise = pools.isEnterprise;

        $state.transitionTo(scope.model.initialized ? scope.model.isAuth ? 'app.overview' : 'auth' : 'wizard.welcome');
      }
      function getPools() {
        return $http({method: 'GET', url: '/pools', requestType: 'json'}).success(onPools);
      }

      scope.entryPoint = getPools;

      return scope;
    }]);


