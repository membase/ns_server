angular.module('wizard')
  .controller('wizard.welcome.Controller',
    ['$scope', 'dialog',
      function ($scope, dialog) {
        $scope.focusMe = true;
        $scope.showAboutDialog = function showAboutDialog() {

          dialog.open({
            template: '/angular/dialogs/about/about.html',
            scope: $scope
          });

          $scope.aboutDialog = true;
        };
      }]);