angular.module('mnSpinner', [
]).directive('mnSpinner', function ($compile, $rootScope) {

  return {
    restrict: 'A',
    scope: {
      mnSpinner: '=',
      minHeight: '@'
    },
    compile: function ($element) {
      var scope = $rootScope.$new();
      $element.append($compile("<div class=\"spinner\" ng-show=\"viewLoading\"></div>")(scope));
      $element.addClass('spinner_wrap');

      return function link($scope) {
        $scope.$watch('mnSpinner', function (mnSpinner) {
          scope.viewLoading = !!mnSpinner;
          $element.css({'min-height': (scope.viewLoading && $scope.minHeight) ? $scope.minHeight : ""});
        });

        $scope.$on('$destroy', function () {
          scope.$destroy();
          scope = null;
        });
      };
    }
  };
});