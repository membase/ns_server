var BucketsSection = {
  cells: {},
  init: function () {
    var self = this;
    var cells = self.cells;

    cells.mode = DAO.cells.mode;

    cells.detailsPageURI = new Cell(function (poolDetails) {
      return poolDetails.buckets.uri;
    }).setSources({poolDetails: DAO.cells.currentPoolDetails});

    self.settingsWidget = new MultiDrawersWidget({
      hashFragmentParam: "buckets",
      template: "bucket_settings",
      placeholderCSS: '#buckets .settings-placeholder',
      elementsKey: 'name',
      drawerCellName: 'settingsCell',
      idPrefix: 'settingsRowID',
      actionLink: 'visitBucket',
      actionLinkCallback: function () {
        ThePage.ensureSection('buckets');
      },
      valueTransformer: function (bucketInfo, bucketSettings) {
        var rv = _.extend({}, bucketInfo, bucketSettings);
        delete rv.settingsCell;
        return rv;
      }
    });

    var poolDetailsValue;
    DAO.cells.currentPoolDetails.subscribeValue(function (v) {
      if (!v)
        return;

      poolDetailsValue = v;
    });

    var bucketsListTransformer = function (values) {
      self.buckets = values;
      _.each(values, function (bucket) {
        bucket.serversCount = poolDetailsValue.nodes.length;
        bucket.ramQuota = bucket.totalSizeMB * 1048576;
        var storageTotals = poolDetailsValue.storageTotals
        bucket.totalRAMSize = storageTotals.ram.total;
        bucket.totalRAMUsed = bucket.basicStats.memUsed;
        bucket.otherRAMSize = storageTotals.ram.used - bucket.totalRAMUsed;
        bucket.totalRAMFree = storageTotals.ram.total - storageTotals.ram.used;

        bucket.RAMUsedPercent = calculatePercent(bucket.totalRAMUsed, bucket.totalRAMSize);
        bucket.RAMOtherPercent = calculatePercent(bucket.totalRAMUsed + bucket.otherRAMSize, bucket.totalRAMSize);

        bucket.totalDiskSize = storageTotals.hdd.total;
        bucket.totalDiskUsed = bucket.basicStats.diskUsed;
        bucket.otherDiskSize = storageTotals.hdd.used - bucket.totalDiskUsed;
        bucket.totalDiskFree = storageTotals.hdd.total - storageTotals.hdd.used;

        bucket.diskUsedPercent = calculatePercent(bucket.totalDiskUsed, bucket.totalDiskSize);
        bucket.diskOtherPercent = calculatePercent(bucket.otherDiskSize + bucket.totalDiskUsed, bucket.totalDiskSize);
      });
      values = self.settingsWidget.valuesTransformer(values);
      return values;
    }
    cells.detailedBuckets = new Cell(function (pageURI) {
      return future.get({url: pageURI}, bucketsListTransformer, this.self.value);
    }).setSources({pageURI: cells.detailsPageURI});

    renderCellTemplate(cells.detailedBuckets, 'bucket_list');

    self.settingsWidget.hookRedrawToCell(cells.detailedBuckets);
  },
  buckets: null,
  refreshBuckets: function (callback) {
    var cell = this.cells.detailedBuckets;
    if (callback) {
      cell.changedSlot.subscribeOnce(callback);
    }
    cell.invalidate();
  },
  withBucket: function (uri, body) {
    if (!this.buckets)
      return;
    var buckets = this.buckets || [];
    var bucketInfo = _.detect(buckets, function (info) {
      return info.uri == uri;
    });

    if (!bucketInfo) {
      console.log("Not found bucket for uri:", uri);
      return null;
    }

    return body.call(this, bucketInfo);
  },
  findBucket: function (uri) {
    return this.withBucket(uri, function (r) {return r});
  },
  showBucket: function (uri) {
    this.withBucket(uri, function (bucketDetails) {
      var values = _.extend({}, bucketDetails, bucketDetails.settingsCell.value);
      var uri = function (data, cb) {
        alert('posted!');
        return cb('', 'success');
      }
      runFormDialog(uri, 'bucket_details_dialog', {
        initialValues: values
      });
    });
  },
  startFlushCache: function (uri) {
    hideDialog('bucket_details_dialog_container');
    this.withBucket(uri, function (bucket) {
      renderTemplate('flush_cache_dialog', {bucket: bucket});
      showDialog('flush_cache_dialog_container');
    });
  },
  completeFlushCache: function (uri) {
    hideDialog('flush_cache_dialog_container');
    this.withBucket(uri, function (bucket) {
      $.post(bucket.flushCacheUri);
    });
  },
  getPoolNodesCount: function () {
    return DAO.cells.currentPoolDetails.value.nodes.length;
  },
  onEnter: function () {
    this.refreshBuckets();
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  },
  onLeave: function () {
    this.settingsWidget.reset();
  },
  checkFormChanges: function () {
    var parent = $('#add_new_bucket_dialog');

    var cache = parent.find('[name=cacheSize]').val();
    if (cache != this.lastCacheValue) {
      this.lastCacheValue = cache;

      var cacheValue;
      if (/^\s*\d+\s*$/.exec(cache)) {
        cacheValue = parseInt(cache, 10);
      }

      var detailsText;
      if (cacheValue != undefined) {
        var nodesCnt = this.getPoolNodesCount();
        detailsText = [" MB x ",
                       nodesCnt,
                       " server nodes = ",
                       ViewHelpers.formatQuantity(cacheValue * nodesCnt * 1024 *1024),
                       " Total Cache Size/",
                       // TODO: will probably die
                       ViewHelpers.formatQuantity(OverviewSection.clusterMemoryAvailable),
                       " Cluster Memory Available"].join('')
      } else {
        detailsText = "";
      }
      parent.find('.cache-details').html(escapeHTML(detailsText));
    }
  },
  startCreate: function () {
    var parent = $('#add_new_bucket_dialog');

    var inputs = parent.find('input[type=text]');
    inputs = inputs.add(parent.find('input[type=password]'));
    inputs.val('');
    $('#add_new_bucket_errors_container').empty();
    this.lastCacheValue = undefined;

    var observer = parent.observePotentialChanges($m(this, 'checkFormChanges'));

    parent.find('form').bind('submit', function (e) {
      e.preventDefault();
      BucketsSection.createSubmit();
    });

    parent.find('[name=cacheSize]').val('64');

    showDialog(parent, {
      onHide: function () {
        observer.stopObserving();
        parent.find('form').unbind();
      }});
  },
  finishCreate: function () {
    hideDialog('add_new_bucket_dialog');
    ThePage.gotoSection('buckets');
  },
  createSubmit: function () {
    var self = this;
    var form = $('#add_new_bucket_form');

    $('#add_new_bucket_errors_container').empty();
    var loading = overlayWithSpinner(form);

    postWithValidationErrors(self.cells.detailsPageURI.value, form, function (data, status) {
      if (status == 'error') {
        loading.remove();
        renderTemplate("add_new_bucket_errors", data);
      } else {
        DAO.cells.currentPoolDetails.invalidate(function () {
          loading.remove();
          self.finishCreate();
        });
      }
    });
  },
  // TODO: currently inaccessible from UI
  startRemovingBucket: function () {
    if (!this.currentlyShownBucket)
      return;

    hideDialog('bucket_details_dialog_container');

    $('#bucket_remove_dialog .bucket_name').text(this.currentlyShownBucket.name);
    showDialog('bucket_remove_dialog');
  },
  // TODO: currently inaccessible from UI
  removeCurrentBucket: function () {
    var self = this;

    var bucket = self.currentlyShownBucket;
    if (!bucket)
      return;

    hideDialog('bucket_details_dialog_container');

    var spinner = overlayWithSpinner('#bucket_remove_dialog');
    var modal = new ModalAction();
    $.ajax({
      type: 'DELETE',
      url: self.currentlyShownBucket.uri,
      success: continuation,
      errors: continuation
    });
    return;

    function continuation() {
      self.refreshBuckets(continuation2);
    }

    function continuation2() {
      spinner.remove();
      modal.finish();
      hideDialog('bucket_remove_dialog');
    }
  }
};
