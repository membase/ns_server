(function () {
  "use strict";

  angular
    .module('mnPeriod', [])
    .directive('mnPeriod', mnPeriodDirective);

   function mnPeriodDirective() {
    var mnPeriod = {
      restrict: 'A',
      scope: {
        mnPeriod: "@",
        autoCompactionSettings: '=',
        errors: "=",
        rbac: "="
      },
      templateUrl: 'components/directives/mn_period/mn_period.html'
    };

    return mnPeriod;
  }
})();
