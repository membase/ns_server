(function () {
  "use strict";

  angular
    .module('mnAutoCompactionForm', ['mnPeriod'])
    .directive('mnAutoCompactionForm', mnAutoCompactionFormDirective);

  function mnAutoCompactionFormDirective($http, daysOfWeek, mnPermissions, mnPoolDefault, mnPromiseHelper, mnSettingsClusterService) {
    var mnAutoCompactionForm = {
      restrict: 'A',
      scope: {
        autoCompactionSettings: '=',
        validationErrors: '=',
        isBucketsSettings: '='
      },
      isolate: false,
      replace: true,
      templateUrl: 'app-classic/components/directives/mn_auto_compaction_form/mn_auto_compaction_form.html',
      controller: controller
    };

    function controller($scope) {
      $scope.daysOfWeek = daysOfWeek;
      $scope.rbac = mnPermissions.export;
      $scope.poolDefault = mnPoolDefault.export;

      if (mnPoolDefault.export.compat.atLeast40 && $scope.rbac.cluster.indexes.read) {
        mnPromiseHelper($scope, mnSettingsClusterService.getIndexSettings())
          .applyToScope("indexSettings");
      }
    }

    return mnAutoCompactionForm;
  }
})();
