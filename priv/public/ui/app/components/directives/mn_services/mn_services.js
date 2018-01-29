(function () {
  "use strict";

  angular
    .module('mnServices', [])
    .directive('mnServices', mnServicesDirective);

  function mnServicesDirective(mnPools) {
    var mnServices = {
      restrict: 'A',
      scope: {
        config: '=mnServices',
        mnIsEnterprise: "="
      },
      templateUrl: 'app/components/directives/mn_services/mn_services.html'
    };

    return mnServices;
  }
})();
