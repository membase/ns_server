(function () {
  "use strict";

  angular
    .module("mnViews")
    .controller("mnViewsEditingResultController", mnViewsEditingResultController);

  function mnViewsEditingResultController($scope, $state, mnPromiseHelper, mnViewsEditingService, viewsPerPageLimit) {
    var vm = this;

    if ($state.params.isSpatial) {
      vm.filterItems = {
        stale: true,
        connectionTimeout: true,
        bbox: true,
        startRange: true,
        endRange: true
      };
    } else {
      vm.filterItems = {
        stale: true,
        connectionTimeout: true,
        descending: true,
        startkey: true,
        endkey: true,
        startkeyDocid: true,
        endkeyDocid: true,
        group: true,
        groupLevel: true,
        inclusiveEnd: true,
        key: true,
        keys: true,
        reduce: true
      };
    }

    vm.onFilterClose = onFilterClose;
    vm.onFilterOpen = onFilterOpen;
    vm.onFilterReset = onFilterReset;
    vm.isPrevDisabled = isPrevDisabled;
    vm.isNextDisabled = isNextDisabled;
    vm.nextPage = nextPage;
    vm.prevPage = prevPage;
    vm.loadSampleDocument = loadSampleDocument;
    vm.generateViewHref = generateViewHref;
    vm.getFilterParamsAsString = mnViewsEditingService.getFilterParamsAsString;
    vm.filterParams = mnViewsEditingService.getFilterParams();
    vm.activate = activate;

    activate();

    function onFilterReset() {
      vm.filterParams = mnViewsEditingService.getInitialViewsFilterParams($state.params.isSpatial);
    }

    function generateViewHref() {
      return $scope.viewsEditingCtl.state &&
            ($scope.viewsEditingCtl.state.capiBase +
              mnViewsEditingService.buildViewUrl($state.params) +
              mnViewsEditingService.getFilterParamsAsString());
    }

    function nextPage() {
      $state.go('app.admin.indexes.views.editing.result', {
        pageNumber: $state.params.pageNumber + 1
      });
    }
    function prevPage() {
      var prevPage = $state.params.pageNumber - 1;
      prevPage = prevPage < 0 ? 0 : prevPage;
      $state.go('app.admin.indexes.views.editing.result', {
        pageNumber: prevPage
      });
    }
    function loadSampleDocument(id) {
      $state.go('app.admin.indexes.views.editing.result', {
        sampleDocumentId: id
      });
    }
    function isEmptyState() {
      return !vm.state || vm.state.isEmptyState;
    }
    function isPrevDisabled() {
      return isEmptyState() || vm.viewLoading || $state.params.pageNumber <= 0;
    }
    function isNextDisabled() {
      return isEmptyState() || vm.viewLoading || !vm.state.rows || vm.state.rows.length < viewsPerPageLimit || $state.params.pageNumber >= 15;
    }
    function onFilterClose(params) {
      $state.go('app.admin.indexes.views.editing.result', {
        viewsParams: JSON.stringify(params)
      });
      $scope.viewsEditingCtl.isFilterOpened = false;
    }
    function onFilterOpen() {
      $scope.viewsEditingCtl.isFilterOpened = true;
    }
    function activate() {
      mnPromiseHelper(vm, mnViewsEditingService.getViewResult($state.params))
        .showSpinner()
        .catchErrors()
        .applyToScope("state")
        .cancelOnScopeDestroy($scope);
    }
  }
})();
