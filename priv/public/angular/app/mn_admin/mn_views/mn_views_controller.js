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
      'ngSanitize',
      'mnPoolDefault'
    ])
    .controller("mnViewsController", mnViewsController);

    function mnViewsController($scope, $state, mnPoll, $q, mnViewsListService, mnPoolDefault) {

      var vm = this;
      vm.getKvNodeLink = getKvNodeLink;
      vm.mnPoolDefault = mnPoolDefault.latestValue();

      if (!vm.mnPoolDefault.value.isKvNode) {
        return;
      }
      activate();

      function getKvNodeLink() {
        return mnViewsListService.getKvNodeLink(vm.mnPoolDefault.value.nodes);
      }

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
            return mnViewsListService.prepareBucketsDropdownData($state.params, true);
          })
          .subscribe("mnViewsState", vm)
          .keepIn("app.admin.views", vm)
          .cancelOnScopeDestroy()
          .cycle();
      }
    }
})();
