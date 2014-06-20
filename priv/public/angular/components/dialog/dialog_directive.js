angular.module('dialog').directive('dialog', function ($compile) {

  return {
    restrict: 'A',
    scope: {
      dialogShow: '=',
      dialogTitle: '@',
      dialogWidth: '@'
    },
    replace: true,
    transclude: true,
    link: function ($scope, $element, $attrs) {

      $scope.dialogStyle = {
        width: $scope.dialogWidth
      };

      $scope.hideDialog = function() {
        $element.remove();
        $scope.dialogShow = false;
      };
    },
    templateUrl: '/angular/components/dialog/dialog_directive.html'
  };
});