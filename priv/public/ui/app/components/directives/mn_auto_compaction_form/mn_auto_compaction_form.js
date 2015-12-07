(function () {
  "use strict";

  angular
    .module('mnAutoCompactionForm', [
      'mnPoolDefault'
    ])
    .directive('mnAutoCompactionForm', mnAutoCompactionFormDirective);

  function mnAutoCompactionFormDirective($http, mnPoolDefault) {
    var mnAutoCompactionForm = {
      restrict: 'A',
      scope: {
        autoCompactionSettings: '=',
        validationErrors: '='
      },
      isolate: false,
      replace: true,
      templateUrl: 'app/components/directives/mn_auto_compaction_form/mn_auto_compaction_form.html',
      controller: controller
    };

    return mnAutoCompactionForm;

    function controller($scope) {
      $scope.mnPoolDefault = mnPoolDefault.latestValue();
      if ($scope.mnPoolDefault.value.isROAdminCreds) {
        return;
      }
      $scope.$watch('validationErrors', function (errors) {
        angular.forEach($scope.validationErrors, function (value, key) {
          $scope.validationErrors[key.replace('[', '_').replace(']', '_')] = value;
        });
        $scope.errors = $scope.validationErrors;
      });
    }
  }
})();
