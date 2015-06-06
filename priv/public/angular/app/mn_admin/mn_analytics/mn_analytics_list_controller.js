angular.module('mnAnalytics').controller('mnAnalyticsListController',
  function ($scope, mnHelper) {
    mnHelper.initializeDetailsHashObserver($scope, 'openedStatsBlock', 'app.admin.analytics.list.graph');
  });