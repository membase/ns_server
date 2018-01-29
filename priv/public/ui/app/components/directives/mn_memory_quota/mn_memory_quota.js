(function () {
  "use strict";

  angular
    .module('mnMemoryQuota', [
      'mnServices',
      'mnFocus'
    ])
    .directive('mnMemoryQuota', mnMemoryQuotaDirective);

  function mnMemoryQuotaDirective() {
    var mnMemoryQuota = {
      restrict: 'A',
      scope: {
        config: '=mnMemoryQuota',
        errors: "=",
        rbac: "=",
        mnIsEnterprise: "="
      },
      templateUrl: 'app/components/directives/mn_memory_quota/mn_memory_quota.html',
      controller: controller
    };

    return mnMemoryQuota;

    function controller($scope) {
      //hack for avoiding access to $parent scope from child scope via propery "$parent"
      //should be removed after implementation of Controller As syntax
      $scope.mnMemoryQuotaController = $scope;
    }
  }
})();
