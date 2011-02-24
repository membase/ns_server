var MonitorBucketsSection = {
  init: function () {
    var detailedBuckets = BucketsSection.cells.detailedBuckets;

    var membaseBuckets = new Cell(function (detailedBuckets) {
      return _.select(detailedBuckets, function (bucketInfo) {
        return bucketInfo.bucketType == 'membase';
      });
    }, {
      detailedBuckets: detailedBuckets
    });
    renderCellTemplate(membaseBuckets, 'monitor_persistent_buckets_list');

    var memcachedBuckets = new Cell(function (detailedBuckets) {
      return _.select(detailedBuckets, function (bucketInfo) {
        return bucketInfo.bucketType != 'membase';
      });
    }, {
      detailedBuckets: detailedBuckets
    });
    renderCellTemplate(memcachedBuckets, 'monitor_cache_buckets_list');

    memcachedBuckets.subscribeValue(function (list) {
      $('#monitor_buckets .memcached-buckets-subsection')[!list || list.length ? 'show' : 'hide']();
    });
    membaseBuckets.subscribeValue(function (list) {
      $('#monitor_buckets .membase-buckets-subsection')[!list || list.length ? 'show' : 'hide']();
    });

    detailedBuckets.subscribeValue(function (list) {
      var empty = list && list.length == 0;
      $('#monitor_buckets .no-buckets-subsection')[empty ? 'show' : 'hide']();
    });

    var stalenessCell = Cell.compute(function (v) {return v.need(detailedBuckets.ensureMetaCell()).stale});

    stalenessCell.subscribeValue(function (stale) {
      if (stale === undefined)
        return;
      $('#monitor_buckets .staleness-notice')[stale ? 'show' : 'hide']();
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
