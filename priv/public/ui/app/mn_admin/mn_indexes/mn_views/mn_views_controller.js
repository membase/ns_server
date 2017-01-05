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
      vm.onSelectBucket = onSelectBucket;
      vm.mnPoolDefault = mnPoolDefault.latestValue();
      vm.ddocsLoading = true;
      vm.kvNodeLink = "";

      activate();

      function onSelectBucket(selectedBucket) {
        $state.go('^.list', {bucket: selectedBucket});
      }

      function activate() {
        if (vm.mnPoolDefault.value.isKvNode) {
          new mnPoller($scope, function () {
            return mnViewsListService.prepareBucketsDropdownData($state.params);
          })
            .reloadOnScopeEvent("bucketUriChanged")
            .subscribe("state", vm)
            .cycle();
        }
        else {
          var urls = mnPoolDefault.getUrlsRunningService(vm.mnPoolDefault.value.nodes, "kv", 1);
          vm.kvNodeLink = urls && urls.length > 0 ? urls[0] : "";
        }
      }
    }
})();
