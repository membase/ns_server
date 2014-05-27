angular.module('auth', ['auth.service'])
  .controller('auth.Controller',
    ['$scope', 'auth.service',
      function ($scope, authService) {
        $scope.loginFailed = false;

        function error() {
          $scope.loginFailed = true;
        }
        function success() {
          $scope.loginFailed = false;
        }

        $scope.submit = function submit() {
          authService.manualLogin($scope.user).success(success).error(error);
        }
      }]);