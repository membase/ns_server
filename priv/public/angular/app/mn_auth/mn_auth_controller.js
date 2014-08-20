angular.module('mnAuth').controller('mnAuthController',
  function ($scope, mnAuthService) {
    $scope.loginFailed = false;

    function error() {
      $scope.loginFailed = true;
    }
    function success() {
      $scope.loginFailed = false;
    }

    $scope.submit = function () {
      mnAuthService.manualLogin($scope.user).success(success).error(error);
    }
  });