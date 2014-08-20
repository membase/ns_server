angular.module('mnFocus').directive('mnFocusDirective', function () {

  return {
    scope: {
      mnFocusDirective: "="
    },
    link: function ($scope, $element, $attrs) {
      $scope.$watch('mnFocusDirective', function (focus) {
        focus && $element[0].focus();
      });

      $element.bind('blur', function () {
        $scope.mnFocusDirective = false;
        $scope.$apply();
      });

      $scope.mnFocusDirective = true;
    }
  };
});