(function () {
  "use strict";

  angular
    .module('mnAnalytics')
    .controller('mnAnalyticsListController', mnAnalyticsListController);

  function mnAnalyticsListController(mnHelper, $state) {
    var vm = this;
    var expanderStateParamName = $state.params.specificStat ? 'openedSpecificStatsBlock' : 'openedStatsBlock';
    mnHelper.initializeDetailsHashObserver(vm, expanderStateParamName, 'app.admin.analytics.list.graph');
  }
})();
