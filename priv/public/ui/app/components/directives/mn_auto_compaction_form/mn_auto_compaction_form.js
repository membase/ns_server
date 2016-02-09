(function () {
  "use strict";

  angular
    .module('mnAutoCompactionForm', [])
    .directive('mnAutoCompactionForm', mnAutoCompactionFormDirective);

  function mnAutoCompactionFormDirective($http) {
    var mnAutoCompactionForm = {
      restrict: 'A',
      scope: {
        autoCompactionSettings: '=',
        validationErrors: '=',
        isBucketsSettings: '='
      },
      isolate: false,
      replace: true,
      templateUrl: 'app/components/directives/mn_auto_compaction_form/mn_auto_compaction_form.html',
      controller: controller
    };

    return mnAutoCompactionForm;

    function controller($scope) {
      $scope.$watch('validationErrors', function (errors) {
        angular.forEach($scope.validationErrors, function (value, key) {
          $scope.validationErrors[key.replace('[', '_').replace(']', '_')] = value;
        });
        $scope.errors = $scope.validationErrors;
      });
    }
  }
})();
