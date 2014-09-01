angular.module('mnDialog').directive('mnDialogDirective', function ($compile, mnDialogService) {

  return {
    restrict: 'A',
    scope: {
      mnDialogTitle: '@',
      mnDialogWidth: '@'
    },
    isolate: false,
    replace: true,
    transclude: true,
    link: function ($scope, $element, $attrs) {

      $scope.dialogStyle = {
        width: $scope.mnDialogWidth
      };

      $scope.hide = function () {
        mnDialogService.removeLastOpened();
      };
    },
    templateUrl: 'components/mn_dialog/mn_dialog_directive.html'
  };
});