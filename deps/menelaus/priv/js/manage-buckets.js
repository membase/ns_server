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
        bucket.ramQuota = bucket.quota.ram;
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

    $('.create-bucket-button').live('click', function (e) {
      e.preventDefault();
      BucketsSection.startCreate();
    });
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
  runBucketDetailsDialog: function (initValues, isNew) {
    var poolDetails = DAO.cells.currentPoolDetailsCell.value;

    initValues['ramQuotaMB'] = Math.floor(initValues.quota.ram / 1048576);
    initValues['hddQuotaGB'] = Math.floor(initValues.quota.hdd / (1048576 * 1024));
    initValues.otherQuota = {
      ram: poolDetails.storageTotals.ram.quotaUsed,
      hdd: poolDetails.storageTotals.hdd.quotaUsed
    }
    if (!isNew) {
      initValues.otherQuota.ram -= initValues.quota.ram;
      initValues.otherQuota.hdd -= initValues.quota.hdd;
    }
    initValues.errors = {ram: null, hdd: null};

    var valuesCell = (function () {
      var cell = new Cell();
      cell.setValue(initValues);
      return cell;
    })();

    var dialog = $('#bucket_details_dialog');
    dialog.removeClass('editing').removeClass('creating');
    dialog.addClass(isNew ? 'creating' : 'editing');

    setBoolAttribute(dialog.find('[name=name]'), 'disabled', !isNew);

    valuesCell.subscribeValue(function (values) {
      if (!values)
        return;

      function renderGauge(jq, total, thisBucket, used) {
        var thisValue = thisBucket
        var formattedBucket = ViewHelpers.formatQuantity(thisBucket, null, null, ' ');

        if (_.isString(thisValue)) {
          formattedBucket = thisValue;
          thisValue = 0;
        }

        jq.find('.total').text(ViewHelpers.formatQuantity(total, null, null, ' '));
        var free = total - used - thisValue;
        jq.find('.free').text(ViewHelpers.formatQuantity(free, null, null, ' '));
        jq.find('.other').text(ViewHelpers.formatQuantity(used, null, null, ' '));
        jq.find('.this').text(formattedBucket);

        jq.find('.gauge .green').css('width', calculatePercent(used + thisValue, total) + '%');
        jq.find('.gauge .blue').css('width', calculatePercent(used, total) + '%');
      }

      renderGauge(dialog.find(".size-gauge.for-ram"),
                  poolDetails.storageTotals.ram.quotaTotal,
                  values.quota.ram,
                  values.otherQuota.ram);

      renderGauge(dialog.find('.size-gauge.for-hdd'),
                  poolDetails.storageTotals.hdd.quotaTotal,
                  values.quota.hdd,
                  values.otherQuota.hdd);

      function renderError(label, error) {
        label.find('input')[error ? 'addClass' : 'removeClass']('invalid');
        label.next('.error-container').text(error || '')[error ? 'addClass' : 'removeClass']('active');
      }

      renderError(dialog.find('.for-ram-quota'), values.errors.ram);
      renderError(dialog.find('.for-hdd-quota'), values.errors.hdd);
    });

    var cleanups = [];

    runFormDialog(initValues.uri, 'bucket_details_dialog', {
      initialValues: valuesCell.value,
      closeCallback: function () {
        _.each(cleanups, function (c) {
          c();
          BucketsSection.refreshBuckets();
        });
      }
    });

    function handleQuotaValidation(storageType) {
      var props = {
        name: 'ramQuotaMB',
        unitSize: 1048576
      }
      if (storageType == 'hdd') {
        props = {
          name: 'hddQuotaGB',
          unitSize: (1048576*1024)
        }
      }

      function validation(newValue) {
        var storageInfo = poolDetails.storageTotals[storageType];
        var oldThisQuota = initValues.quota[storageType];
        var other = initValues.otherQuota[storageType];
        var max = storageInfo.quotaTotal - other;
        var min = 10 * props.unitSize; // TODO

        max = Math.floor(max / props.unitSize);
        min = Math.floor(min / props.unitSize);
        if (min >= max)
          min = max >> 1;

        var parsedQuota = parseValidateInteger(newValue, min, max);

        var error = $(this).closest('label').next('.error-container');
        var errorText;
        if (typeof(parsedQuota) == 'string') {
          errorText = parsedQuota;
          parsedQuota = '??';
        } else {
          parsedQuota *= props.unitSize;
        }

        valuesCell.setValueAttr(parsedQuota, 'quota', storageType);
        valuesCell.setValueAttr(errorText, 'errors', storageType);
      }

      var input = dialog.find('[name='+props.name+']');
      var observer = input.observeInput(validation);

      cleanups.push(function () {
        observer.stopObserving();
      });

      validation(input.val());
    }

    handleQuotaValidation('ram');
    handleQuotaValidation('hdd');

    (function () {
      var enableReplicationCheckbox = dialog.find('[name=enableReplication]');
      var replicaNumberInput = dialog.find('[name=replicaNumber]');
      var preDisableReplicaNumber = replicaNumberInput.val();
      enableReplicationCheckbox.bind('click', function () {
        setBoolAttribute(replicaNumberInput, 'disabled', !this.checked);
        if (!this.checked) {
          preDisableReplicaNumber = replicaNumberInput.val();
          replicaNumberInput.val('0');
        } else {
          replicaNumberInput.val(preDisableReplicaNumber);
        }
      });
      cleanups.push(function () {
        enableReplicationCheckbox.unbind('click');
      });

      function validateReplicas(newValue) {
        var value = parseValidateInteger(newValue, 0, 1024); //poolDetails.nodes.length-1);
        var errorsContainer = dialog.find('.for-replica-number .error-container');
        var error;
        if (_.isString(value)) {
          error = value;
          errorsContainer.text(error);
        }
        errorsContainer[error ? 'addClass' : 'removeClass']('active');
        replicaNumberInput[error ? 'addClass' : 'removeClass']('invalid');
        valuesCell.setValueAttr(error, 'errors', 'replicas');
      }

      var observer = replicaNumberInput.observeInput(validateReplicas);
      cleanups.push(function () {
        observer.stopObserving();
      });
      validateReplicas(preDisableReplicaNumber);

      valuesCell.subscribeValue(function (values) {
        if (!values)
          return;

        var hasErrors = _.some(_.keys(values.errors), function (k) {
          return !!(values.errors[k]);
        });

        setBoolAttribute(dialog.find('.save_button'), 'disabled', hasErrors);
      });
    })();
  },
  showBucket: function (uri) {
    ThePage.ensureSection('buckets');
    if (!DAO.cells.currentPoolDetailsCell.value) {
      // if don't have pool details wait for them
      DAO.cell.currentPoolDetailsCell.subscribeOnce(function () {
        _.defer(function () {
          BucketsSection.showBucket(uri)
        });
      });
      return;
    }
    this.withBucket(uri, function (bucketDetails) {
      var initValues = _.extend({}, bucketDetails, bucketDetails.settingsCell.value);
      BucketsSection.runBucketDetailsDialog(initValues, false);
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
    var totals = DAO.cells.currentPoolDetails.value.storageTotals;
    if (totals.ram.quotaTotal == totals.ram.quotaUsed || totals.hdd.quotaTotal == totals.hdd.quotaUsed) {
      alert('TODO: No free quota left!')
      return;
    }
    this.runBucketDetailsDialog({uri: '/pools/default/buckets',
                                 quota: {ram: totals.ram.quotaTotal - totals.ram.quotaUsed,
                                         hdd: totals.hdd.quotaTotal - totals.hdd.quotaUsed},
                                 replicaNumber: 1}, true);
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

configureActionHashParam("editBucket", $m(BucketsSection, 'showBucket'));

// $(function () {
//   var oldIsSasl;
//   var dialog = $('#bucket_details_dialog')
//   dialog.observePotentialChanges(function () {
//     var isSasl = $('#bucket_details_sasl_selected')[0].checked;
//     if (oldIsSasl != null && isSasl == oldIsSasl)
//       return;
//     oldIsSasl = isSasl;

//     setBoolAttribute(dialog.find('.for-sasl-password-input input'), 'disabled', !isSasl);
//     setBoolAttribute(dialog.find('.for-proxy-port input'), 'disabled', isSasl);
//   });
// });
