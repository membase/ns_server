(function () {
  "use strict";

  angular
    .module('mnAutoCompactionForm', ['mnPeriod'])
    .directive('mnAutoCompactionForm', mnAutoCompactionFormDirective);

  function mnAutoCompactionFormDirective($http, daysOfWeek) {
    var mnAutoCompactionForm = {
      restrict: 'A',
      scope: {
        autoCompactionSettings: '=',
        validationErrors: '=',
        isBucketsSettings: '=',
        rbac: "=",
        poolDefault: "="
      },
      isolate: false,
      replace: true,
      templateUrl: 'app/components/directives/mn_auto_compaction_form/mn_auto_compaction_form.html',
      controller: controller
    };

    function controller($scope, daysOfWeek) {
      $scope.daysOfWeek = daysOfWeek;
    }

    return mnAutoCompactionForm;
  }
})();
