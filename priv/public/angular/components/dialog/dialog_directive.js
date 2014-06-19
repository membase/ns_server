angular.module('dialog', []).directive('dialog', function () {

  return {
    restrict: 'A',
    scope: {
      dialogShow: '=',
      dialogTitle: '@',
      dialogWidth: '@'
    },
    isolate: false,
    replace: true, // Replace with the template below
    transclude: true, // we want to insert custom content inside the directive
    link: function ($scope, $element, $attrs, $ctrl, $transclude) {
      $scope.dialogShow = false;
      $scope.dialogStyle = {
        width: $scope.dialogWidth
      };

      $scope.hideDialog = function() {
        $scope.dialogShow = false;
      };
    },
    templateUrl: 'components/dialog/dialog_directive.html'
  };
});