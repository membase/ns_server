angular.module('app', [
  'app.service',
  'overview.service'
  ]).config(['$stateProvider', '$urlRouterProvider',
    function ($stateProvider, $urlRouterProvider) {

      $urlRouterProvider
        .when('/servers/', '/servers/active');

      $stateProvider
        .state('app', {
          abstract: true,
          templateUrl: '/angular/app.html',
          controller: 'app.Controller'
        })
        .state('app.overview', {
          url: '/overview',
          controller: 'overview.Controller',
          templateUrl: '/angular/app/overview/overview.html',
          authenticate: true
        });
    }]);