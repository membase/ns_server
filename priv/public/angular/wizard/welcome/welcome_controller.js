angular.module('wizard')
  .controller('wizard.welcome.Controller',
    ['$scope',
      function ($scope) {
        $scope.focusMe = true;
        $scope.showAboutDialog = function showAboutDialog() {
          $scope.aboutDialog = true;
        };
      }]);