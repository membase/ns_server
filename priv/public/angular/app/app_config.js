angular.module('app').config(function ($httpProvider, $stateProvider, $urlRouterProvider) {
  $httpProvider.defaults.headers.common['invalid-auth-response'] = 'on';
  $httpProvider.defaults.headers.common['Cache-Control'] = 'no-cache';
  $httpProvider.defaults.headers.common['Pragma'] = 'no-cache';
  $httpProvider.defaults.headers.common['ns_server-ui'] = 'yes';

  $stateProvider.state('app', {
    url: '',
    abstract: true,
    template: '<div ui-view="" />',
    controller: 'appController',
    resolve: {
      pools: function (mnPools) {
        return mnPools.get();
      }
    }
  });

  $urlRouterProvider.deferIntercept();
  $urlRouterProvider.otherwise('/overview');
});