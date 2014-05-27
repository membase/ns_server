angular.module('spinner', []).directive('spinner', function () {

  return {
    restrict: 'A',
    scope: {
      spinner: '='
    },
    isolate: false,
    replace: true,
    templateUrl: 'components/spinner_directive.html',
    link: function ($scope, $element, $attrs) {
      var parent = $element.parent().addClass('spinner_wrap');
    }
  };
});