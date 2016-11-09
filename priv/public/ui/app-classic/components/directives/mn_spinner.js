(function () {
  "use strict";

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
        controller: controller,
        bindToController: true,
        controllerAs: "controller",
        link: link
      };

      return directive;

      function controller($scope, $element) {
        var vm = this;
        $scope.$watch('controller.mnSpinner', function (mnSpinner) {
          $element.css({'min-height': (!!mnSpinner && vm.minHeight) ? vm.minHeight : ""});
        });
      }

      function link($scope, $element) {
        $element.append($compile("<div class=\"spinner\" ng-show=\"controller.mnSpinner\"></div>")($scope));
        $element.addClass('spinner_wrap');
      }
    }
})();