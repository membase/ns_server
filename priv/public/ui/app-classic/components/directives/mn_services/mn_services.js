(function () {
  "use strict";

  angular
    .module('mnServices', [])
    .directive('mnServices', mnServicesDirective);

  function mnServicesDirective(mnPools) {
    var mnServices = {
      restrict: 'A',
      scope: {
        config: '=mnServices'
      },
      templateUrl: 'app-classic/components/directives/mn_services/mn_services.html',
      controller: controller
    };

    return mnServices;

    function controller($scope) {
      mnPools.get().then(function (pool) {
        $scope.isEnterprise = pool.isEnterprise;
        $scope.onChange = function (value, model) {
          if (!pool.isEnterprise) {
            $scope.config.services.model[model] = value;
          }
        };
      });
    }
  }
})();
