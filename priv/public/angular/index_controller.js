angular.module('index', [
  'wizard',
  'auth',
  'app',
  'barGauge',
  'focus',
  'dialog',
  'spinner',
  'filters'
]).controller('index.Controller', ['auth.service', '$templateCache', '$http',
  function (authService, $templateCache, $http) {
    'use strict';

    authService.entryPoint();

    _.each(angularTemplatesList, function (url) {
      $http.get("/angular/" + url, {cache: $templateCache});
    });

  }]).run(['$rootScope', '$location', function ($rootScope, $location) {
    $rootScope.$on('$stateChangeStart', function (event, current) {
      this.locationSearch = $location.search();
    });
    $rootScope.$on('$stateChangeSuccess', function () {
      $location.search(this.locationSearch);
    });
  }]);
