angular.module('app').controller('appController',
  function (mnAuthService, $scope, $templateCache, $http, $rootScope, $location, mnDialogService) {
    mnAuthService.entryPoint();

    $scope.mnDialogService = mnDialogService;

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
