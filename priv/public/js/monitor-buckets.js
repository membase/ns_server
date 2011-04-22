/**
   Copyright 2011 Couchbase, Inc.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
 **/
var MonitorBucketsSection = {
  init: function () {
    var bucketsListCell = DAL.cells.bucketsListCell;

    var membaseBuckets = new Cell(function (bucketsList) {
      return _.select(bucketsList, function (bucketInfo) {
        return bucketInfo.bucketType == 'membase';
      });
    }, {
      bucketsList: bucketsListCell
    });
    renderCellTemplate(membaseBuckets, 'monitor_persistent_buckets_list');

    var memcachedBuckets = new Cell(function (bucketsList) {
      return _.select(bucketsList, function (bucketInfo) {
        return bucketInfo.bucketType != 'membase';
      });
    }, {
      bucketsList: bucketsListCell
    });
    renderCellTemplate(memcachedBuckets, 'monitor_cache_buckets_list');

    memcachedBuckets.subscribeValue(function (list) {
      $('#monitor_buckets .memcached-buckets-subsection')[!list || list.length ? 'show' : 'hide']();
    });
    membaseBuckets.subscribeValue(function (list) {
      $('#monitor_buckets .membase-buckets-subsection')[!list || list.length ? 'show' : 'hide']();
    });

    bucketsListCell.subscribeValue(function (list) {
      var empty = (list && list.length == 0);
      $('#monitor_buckets .no-buckets-subsection')[empty ? 'show' : 'hide']();
    });

    var stalenessCell = Cell.compute(function (v) {return v.need(bucketsListCell.ensureMetaCell()).stale});

    stalenessCell.subscribeValue(function (stale) {
      if (stale === undefined)
        return;
      $('#monitor_buckets .staleness-notice')[stale ? 'show' : 'hide']();
    });
  },
  onEnter: function () {
    BucketsSection.refreshBuckets();
  }
};
