(function () {
  "use strict";

  angular
    .module("mnViews", [
      'mnViewsListService',
      'mnViewsEditingService',
      'mnCompaction',
      'mnHelper',
      'mnPromiseHelper',
      'mnPoll',
      'mnFilter',
      'ui.select',
      'ui.router',
      'ui.bootstrap',
      'ngSanitize'
    ])
    .controller("mnViewsController", mnViewsController);

    function mnViewsController($scope, $state, mnPoll, mnViewsListService) {

      var vm = this;

      activate();

      function activate() {
        $scope.$watch('mnViewsController.mnViewsState.bucketsNames.selected', function (selectedBucket) {
          selectedBucket && selectedBucket !== $state.params.viewsBucket && $state.go('app.admin.views.list', {
            viewsBucket: selectedBucket
          }, {
            location: !$state.params.viewsBucket ? "replace" : true
          });
        });
        mnPoll
          .start($scope, function () {
            return mnViewsListService.getViewsState($state.params);
          })
          .subscribe("mnViewsState", vm)
          .keepIn(null, vm)
          .cancelOnScopeDestroy()
          .run();
      }
    }
})();
