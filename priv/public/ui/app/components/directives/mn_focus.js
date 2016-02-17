(function () {
  "use strict";

  angular
    .module('mnFocus', [])
    .directive('mnFocus', mnFocusDirective);

  function mnFocusDirective($parse) {
    var mnFocus = {
      link: link
    };

    return mnFocus;

    function link($scope, $element, $attrs) {
      $scope.$watch($attrs.mnFocus ? $parse($attrs.mnFocus) : function () { return true; }, function (focus) {
        focus && $element[0].focus();
      });

      $element.bind('blur', function () {
        $scope.mnFocus = false;
      });
    }
  }
})();
