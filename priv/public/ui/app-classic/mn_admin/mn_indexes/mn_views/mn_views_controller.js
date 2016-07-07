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

    function mnViewsController($scope, $state, mnPoller, $q, mnViewsListService, mnPoolDefault) {

      var vm = this;
      vm.getKvNodeLink = getKvNodeLink;
      vm.onSelectBucket = onSelectBucket;
      vm.mnPoolDefault = mnPoolDefault.latestValue();

      if (!vm.mnPoolDefault.value.isKvNode) {
        return;
      }
      activate();

      function getKvNodeLink() {
        return mnViewsListService.getKvNodeLink(vm.mnPoolDefault.value.nodes);
      }
      function onSelectBucket(selectedBucket) {
        $state.go('app.admin.indexes.views.list', {viewsBucket: selectedBucket});
      }

      function activate() {
        new mnPoller($scope, function () {
            return mnViewsListService.prepareBucketsDropdownData($state.params);
          })
          .reloadOnScopeEvent("bucketUriChanged")
          .subscribe("state", vm)
          .cycle();
      }
    }
})();
