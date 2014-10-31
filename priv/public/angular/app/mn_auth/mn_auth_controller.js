angular.module('mnAuth').controller('mnAuthController',
  function ($scope, mnAuthService, $window) {
    $scope.loginFailed = false;

    function error() {
      $scope.loginFailed = true;
    }
    function success() {
      $scope.loginFailed = false;
      $window.location.reload();
    }

    $scope.submit = function () {
      mnAuthService.manualLogin($scope.user).then(success, error);
    }
  });