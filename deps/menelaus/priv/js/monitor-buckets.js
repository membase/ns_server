var MonitorBucketsSection = {
  init: function () {
    var membaseBuckets = new Cell(function (detailedBuckets) {
      return _.select(detailedBuckets, function (bucketInfo) {
        return bucketInfo.bucketType == 'membase';
      });
    }, {
      detailedBuckets: BucketsSection.cells.detailedBuckets
    });
    renderCellTemplate(membaseBuckets, 'monitor_persistent_buckets_list');

    var memcachedBuckets = new Cell(function (detailedBuckets) {
      return _.select(detailedBuckets, function (bucketInfo) {
        return bucketInfo.bucketType != 'membase';
      });
    }, {
      detailedBuckets: BucketsSection.cells.detailedBuckets
    });
    renderCellTemplate(memcachedBuckets, 'monitor_cache_buckets_list');
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
