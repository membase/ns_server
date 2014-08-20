angular.module('mnAdmin').config(function ($stateProvider, $urlRouterProvider) {

  $urlRouterProvider
    .when('/servers/', '/servers/active');

  $stateProvider
    .state('app', {
      abstract: true,
      templateUrl: 'mn_admin/mn_admin.html',
      controller: 'mnAdminController'
    })
    .state('app.overview', {
      url: '/overview',
      controller: 'mnAdminOverviewController',
      templateUrl: 'mn_admin/overview/mn_admin_overview.html',
      authenticate: true
    });
});