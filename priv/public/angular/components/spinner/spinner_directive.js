angular.module('spinner', []).directive('spinner', function ($http, $compile) {

  return {
    restrict: 'A',
    scope: {
      spinner: '='
    },
    link: function ($scope, $element, $attrs) {
      $element.addClass('spinner_wrap');
      $element.append($compile("<div class=\"spinner\" ng-show=\"spinner\"></div>")($scope));
    }
  };
});