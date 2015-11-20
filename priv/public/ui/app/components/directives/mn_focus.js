(function () {
  "use strict";

  angular
    .module('mnFocus', [])
    .directive('mnFocus', mnFocusDirective);

  function mnFocusDirective() {
    var mnFocus = {
      scope: {
        mnFocus: "="
      },
      link: link
    };

    return mnFocus;

    function link($scope, $element, $attrs) {
      $scope.$watch('mnFocus', function (focus) {
        focus && $element[0].focus();
      });

      $element.bind('blur', function () {
        $scope.mnFocus = false;
        $scope.$apply();
      });

      $scope.mnFocus = true;
    }
  }
})();
