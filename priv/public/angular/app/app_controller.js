angular.module('app').controller('appController',
  function (mnAuthService, $templateCache, $http, $rootScope, $location) {
    mnAuthService.entryPoint();

    _.each(angularTemplatesList, function (url) {
      $http.get("/angular/" + url, {cache: $templateCache});
    });

    $rootScope.$on('$stateChangeStart', function (event, current) {
      this.locationSearch = $location.search();
    });
    $rootScope.$on('$stateChangeSuccess', function () {
      $location.search(this.locationSearch);
    });
  });
