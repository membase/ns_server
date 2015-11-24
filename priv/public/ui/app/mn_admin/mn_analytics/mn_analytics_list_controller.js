(function () {
  "use strict";

  angular
    .module('mnAnalytics')
    .controller('mnAnalyticsListController', mnAnalyticsListController);

  function mnAnalyticsListController(mnHelper) {
    var vm = this;
    mnHelper.initializeDetailsHashObserver(vm, 'openedStatsBlock', 'app.admin.analytics.list.graph');
  }
})();
