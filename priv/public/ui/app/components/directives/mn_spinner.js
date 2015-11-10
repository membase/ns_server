(function () {
  angular
    .module('mnSpinner', [])
    .directive('mnSpinner', mnSpinnerDirective);

    function mnSpinnerDirective($compile) {
      var directive = {
        restrict: 'A',
        scope: {
          mnSpinner: '=',
          minHeight: '@'
        },
        link: link
      };
      return directive;

      function link($scope, $element) {
        $element.append($compile("<div class=\"spinner\" ng-show=\"mnSpinner\"></div>")($scope));
        $element.addClass('spinner_wrap');

        $scope.$watch('mnSpinner', function (mnSpinner) {
          $element.css({'min-height': (!!mnSpinner && $scope.minHeight) ? $scope.minHeight : ""});
        });
      }
    }
})();