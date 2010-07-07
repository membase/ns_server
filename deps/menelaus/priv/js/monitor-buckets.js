var MonitorBucketsSection = {
  init: function () {
    renderCellTemplate(BucketsSection.cells.detailedBuckets, 'monitor_buckets_list');
  },
  onEnter: function () {
    BucketsSection.refreshBuckets();
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  },
  onLeave: function () {
  }
};
configureActionHashParam('visitStats', $m(AnalyticsSection, 'visitBucket'));
