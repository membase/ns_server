angular.module('mnDialog').directive('mnDialogDirective', function ($compile) {

  return {
    restrict: 'A',
    scope: {
      mnDialogTitle: '@',
      mnDialogWidth: '@'
    },
    replace: true,
    transclude: true,
    link: function ($scope, $element, $attrs) {

      $scope.dialogStyle = {
        width: $scope.mnDialogWidth
      };

      $scope.hideDialog = function () {
        $element.remove();
      };
    },
    templateUrl: 'components/mn_dialog/mn_dialog_directive.html'
  };
});