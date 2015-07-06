angular.module('mnAuth').controller('mnAuthController',
  function ($scope, mnAuthService, $state, mnPools) {
    $scope.loginFailed = false;

    function error() {
      $scope.loginFailed = true;
    }

    $scope.submit = function () {
      mnAuthService.login($scope.user).then(function () {
        return mnPools.getFresh().then(function () {
          $state.go('app.admin.overview');
        });
      }, error);
    }
  });