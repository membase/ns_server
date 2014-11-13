angular.module('mnAuth').controller('mnAuthController',
  function ($scope, mnAuthService, mnHelper) {
    $scope.loginFailed = false;

    function error() {
      $scope.loginFailed = true;
    }
    function success() {
      $scope.loginFailed = false;
      mnHelper.reloadApp();
    }

    $scope.submit = function () {
      mnAuthService.manualLogin($scope.user).then(success, error);
    }
  });