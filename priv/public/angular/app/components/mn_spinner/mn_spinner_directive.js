angular.module('mnSpinner').directive('mnSpinnerDirective', function ($compile, $rootScope) {

  return {
    restrict: 'A',
    scope: {
      mnSpinnerDirective: '='
    },
    compile: function ($element) {
      var scope = $rootScope.$new();
      $element.append($compile("<div class=\"spinner\" ng-show=\"viewLoading\"></div>")(scope));
      $element.addClass('spinner_wrap');

      return function link($scope) {
        $scope.$watch('mnSpinnerDirective', function (mnSpinnerDirective) {
          scope.viewLoading = !!mnSpinnerDirective;
        });

        $scope.$on('$destroy', function () {
          scope.$destroy();
          scope = null;
        });
      };
    }
  };
});