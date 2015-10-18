angular.module('mnServices', [
]).directive('mnServices', function (mnPools) {

  return {
    restrict: 'A',
    scope: {
      config: '=mnServices'
    },
    templateUrl: 'components/directives/mn_services/mn_services.html',
    controller: function ($scope) {
      mnPools.get().then(function (pool) {
        $scope.isEnterprise = pool.isEnterprise;
        $scope.onChange = function (value, model) {
          if (!pool.isEnterprise) {
            $scope.config.services.model[model] = value;
          }
        };
      });
    }
  };
});