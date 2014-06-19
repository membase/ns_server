angular.module('index', [
  'wizard',
  'auth',
  'app',
  'barGauge',
  'focus',
  'dialog',
  'spinner',
  'filters'
]).controller('index.Controller', ['auth.service', function (authService) {

  authService.entryPoint();

}]).run(['$rootScope', '$location', function ($rootScope, $location) {
  $rootScope.$on('$stateChangeStart', function (event, current) {
    this.locationSearch = $location.search();
  });
  $rootScope.$on('$stateChangeSuccess', function () {
    $location.search(this.locationSearch);
  });
}]);