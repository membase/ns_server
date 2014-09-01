angular.module('mnAuth').config( function ($stateProvider, $httpProvider, $urlRouterProvider) {
  $httpProvider.responseInterceptors.push(['$q', '$location', logsOutUserOn401]);

  $urlRouterProvider.when('', '/auth');
  $urlRouterProvider.when('/', '/auth');

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

  $stateProvider.state('auth', {
    url: '/auth',
    templateUrl: 'mn_auth/mn_auth.html',
    controller: 'mnAuthController',
    authenticate: false
  });
});