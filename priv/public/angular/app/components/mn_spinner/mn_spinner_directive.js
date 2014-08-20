angular.module('mnSpinner').directive('mnSpinnerDirective', function ($http, $compile) {

  return {
    compile: function ($element) {
      $element.append("<div class=\"spinner\" ng-show=\"viewLoading\"></div>");
      $element.addClass('spinner_wrap');
    }
  };
});