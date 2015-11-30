(function () {
  "use strict";

  angular
    .module('mnAnalytics', [
      'mnHelper',
      'mnHttp',
      'mnAnalyticsService',
      'ui.router',
      'mnPoll'
    ])
    .controller('mnAnalyticsController', mnAnalyticsController);

  function mnAnalyticsController($scope, mnAnalyticsService, mnHelper, $state, mnHttp, mnPoller) {
    var vm = this;

    vm.computeOps = computeOps;
    vm.onSelectBucket = onSelectBucket;
    vm.onSelectNode = onSelectNode;

    activate();

    function activate() {
      new mnPoller($scope, function (previousResult) {
        return mnAnalyticsService.getStats({$stateParams: $state.params, previousResult: previousResult});
      })
      .setExtractInterval(function (response) {
        //TODO add error handler
        return response.isEmptyState ? 10000 : response.stats.nextReqAfter;
      })
      .subscribe("state", vm)
      .keepIn("app.admin.analytics", vm)
      .cancelOnScopeDestroy()
      .cycle();
    }
    function onSelectBucket(selectedBucket) {
      _.defer(function () { //in order to set selected item into ng-model before state.go
        $state.go('app.admin.analytics.list.graph', {
          analyticsBucket: selectedBucket
        });
      });
    }
    function onSelectNode(selectedHostname) {
      _.defer(function () { //in order to set selected item into ng-model before state.go
        $state.go('app.admin.analytics.list.graph', {
          statsHostname: selectedHostname.indexOf("All Server Nodes") > -1 ? undefined : selectedHostname
        });
      });
    }
    function computeOps(key) {
      return Math.round(key.ops * 100.0) / 100.0;
    }
  }
})();
