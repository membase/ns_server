angular.module('mnFocus').directive('mnFocus', function () {

  return {
    scope: {
      mnFocus: "="
    },
    link: function ($scope, $element, $attrs) {
      $scope.$watch('mnFocus', function (focus) {
        focus && $element[0].focus();
      });

      $element.bind('blur', function () {
        $scope.mnFocus = false;
        $scope.$apply();
      });

      $scope.mnFocus = true;
    }
  };
});