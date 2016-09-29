(function () {
  "use strict";

  angular
    .module('mnVerticalBar', [])
    .directive('mnVerticalBar', mnVerticalBarDirective);

  function mnVerticalBarDirective() {
    var mnVerticalBar = {
      restrict: 'A',
      scope: {
        conf: '='
      },
      isolate: false,
      templateUrl: 'app-classic/components/directives/mn_vertical_bar/mn_vertical_bar.html'
    };
    return mnVerticalBar;
  }
})();
