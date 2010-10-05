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

    memcachedBuckets.subscribeValue(function (list) {
      $('#monitor_buckets .memcached-buckets-subsection')[!list || list.length ? 'show' : 'hide']();
    });
    membaseBuckets.subscribeValue(function (list) {
      $('#monitor_buckets .membase-buckets-subsection')[!list || list.length ? 'show' : 'hide']();
    });
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
