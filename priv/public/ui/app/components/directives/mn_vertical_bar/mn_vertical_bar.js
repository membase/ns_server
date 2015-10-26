angular.module('mnVerticalBar', [
]).directive('mnVerticalBar', function () {

  return {
    restrict: 'A',
    scope: {
      conf: '='
    },
    isolate: false,
    templateUrl: 'app/components/directives/mn_vertical_bar/mn_vertical_bar.html'
  };
});