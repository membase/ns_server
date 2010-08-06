var BucketDetailsDialog = mkClass({
  initialize: function (initValues, isNew) {
    this.isNew = isNew;
    this.poolDetails = DAO.cells.currentPoolDetailsCell.value;
    this.initValues = initValues;
    initValues['ramQuotaMB'] = Math.floor(initValues.quota.ram / 1048576);
    initValues['hddQuotaGB'] = Math.floor(initValues.quota.hdd / (1048576 * 1024));
    initValues.otherQuota = {
      ram: this.poolDetails.storageTotals.ram.quotaUsed,
      hdd: this.poolDetails.storageTotals.hdd.quotaUsed
    }
    if (!isNew) {
      initValues.otherQuota.ram -= initValues.quota.ram;
      initValues.otherQuota.hdd -= initValues.quota.hdd;
    }
    initValues.errors = {};

    this.valuesCell = new Cell();
    this.valuesCell.setValue(initValues);

    this.dialogID = 'bucket_details_dialog'

    var dialog = this.dialog = $('#' + this.dialogID);

    dialog.removeClass('editing').removeClass('creating');
    dialog.addClass(isNew ? 'creating' : 'editing');

    setBoolAttribute(dialog.find('[name=name]'), 'disabled', !isNew);

    this.valuesCell.subscribeValue($m(this, 'onValues'));

    this.cleanups = [];
  },

  bindWithCleanup: function (jq, event, callback) {
    jq.bind(event, callback);
    return function () {
      jq.unbind(event, callback);
    };
  },

  submit: function () {
    var self = this;

    var closeCleanup = self.bindWithCleanup(self.dialog.find('.jqmClose'),
                                            'click',
                                            function (e) {
                                              e.preventDefault();
                                              e.stopPropagation();
                                            });
    self.needBucketsRefresh = true;

    postWithValidationErrors(self.valuesCell.value.uri, self.dialog.find('form'), function (data, status) {
      if (status == 'success') {
        BucketsSection.refreshBuckets(function () {
          self.needBucketsRefresh = false;
          enableForm();
          hideDialog(self.dialogID);
        });
        return;
      }

      enableForm();

      var errors = data[0]; // we expect errors as a hash in this case
      self.valuesCell.setValueAttr(errors, 'errors');
    });

    var toDisable = self.dialog.find('input[type=text], input:not([type]), input[type=checkbox]')
      .filter(':not([disabled])')
      .add(self.dialog.find('button'));

    // we need to disable after post is sent, 'cause disabled inputs are not sent
    toDisable.add(self.dialog).css('cursor', 'wait');
    setBoolAttribute(toDisable, 'disabled', true);

    function enableForm() {
      closeCleanup();
      setBoolAttribute(toDisable, 'disabled', false);
      toDisable.add(self.dialog).css('cursor', 'auto');
    }
  },
  startDialog: function () {
    var self = this;
    var form = this.dialog.find('form');

    setFormValues(form, self.valuesCell.value);

    self.setupQuotaValidation('ram');
    self.setupQuotaValidation('hdd');
    self.setupReplicasValidation();
    if (self.isNew)
      self.setupNameValidation();

    self.cleanups.push(self.bindWithCleanup(form, 'submit', function (e) {
      e.preventDefault();
      self.submit();
    }));

    showDialog(this.dialogID, {
      onHide: function () {
        self.cleanup();
        if (self.needBucketsRefresh)
          BucketsSection.refreshBuckets();
      }
    });
  },
  cleanup: function () {
    _.each(this.cleanups, function (c) {
      c();
    });
  },

  renderGauge: function (jq, total, thisBucket, used) {
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
  },

  renderError: function (field, error) {
    this.dialog.find('.error-container.err-' + field).text(error || '')[error ? 'addClass' : 'removeClass']('active');
    this.dialog.find('[name=' + field + ']')[error ? 'addClass' : 'removeClass']('invalid');
  },

  // this updates our gauges and errors
  // we don't use it to set input values, 'cause for the later we need to do it once
  onValues: function (values) {
    if (!values)
      return;

    this.renderGauge(this.dialog.find(".size-gauge.for-ram"),
                     this.poolDetails.storageTotals.ram.quotaTotal,
                     values.quota.ram,
                     values.otherQuota.ram);

    this.renderGauge(this.dialog.find('.size-gauge.for-hdd'),
                     this.poolDetails.storageTotals.hdd.quotaTotal,
                     values.quota.hdd,
                     values.otherQuota.hdd);

    this.renderError('name', values.errors.name);
    this.renderError('ramQuotaMB', values.errors.ramQuotaMB);
    this.renderError('hddQuotaGB', values.errors.hddQuotaGB);
    this.renderError('replicaNumber', values.errors.replicaNumber);

    var hasErrors = _.some(_.keys(values.errors), function (k) {
      return !!(values.errors[k]);
    });

    setBoolAttribute(this.dialog.find('.save_button'), 'disabled', hasErrors);
  },

  setupQuotaValidation: function (storageType) {
    var self = this;

    var props = {
      name: 'ramQuotaMB',
      unitSize: 1048576,
      minSize: 128
    }
    if (storageType == 'hdd') {
      props = {
        name: 'hddQuotaGB',
        unitSize: (1048576*1024),
        minSize: 1
      }
    }

    var input = self.dialog.find('[name='+props.name+']');
    var observer = input.observeInput(validate);

    self.cleanups.push(function () {
      observer.stopObserving();
    });

    validate.call(input, input.val());

    function validate(newValue) {
      var storageInfo = self.poolDetails.storageTotals[storageType];
      var oldThisQuota = self.initValues.quota[storageType];
      var other = self.initValues.otherQuota[storageType];
      var max = storageInfo.quotaTotal - other;
      var min = props.minSize; // TODO

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

      self.valuesCell.setValueAttr(parsedQuota, 'quota', storageType);
      self.valuesCell.setValueAttr(errorText, 'errors', props.name);
    }
  },

  setupReplicasValidation: function () {
    var self = this;

    var enableReplicationCheckbox = self.dialog.find('.for-enable-replication input');
    var replicaNumberInput = self.dialog.find('[name=replicaNumber]');
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
    self.cleanups.push(function () {
      enableReplicationCheckbox.unbind('click');
    });

    function validateReplicas(newValue) {
      var value = parseValidateInteger(newValue, 0, 1024); //poolDetails.nodes.length-1);
      var errorsContainer = self.dialog.find('.for-replica-number .error-container');
      var error;
      if (_.isString(value)) {
        error = value;
        errorsContainer.text(error);
      }
      self.valuesCell.setValueAttr(error, 'errors', 'replicaNumber');
    }

    var observer = replicaNumberInput.observeInput(validateReplicas);
    self.cleanups.push(function () {
      observer.stopObserving();
    });
    validateReplicas(preDisableReplicaNumber);
  },

  setupNameValidation: function () {
    var self = this;

    var observer = self.dialog.find('[name=name]').observeInput(function (value) {
      var error = null;
      if (value.length == 0)
        error = 'name cannot be empty';
      self.valuesCell.setValueAttr(error, 'errors', 'name');
    });
    self.cleanups.push(function () {
      observer.stopObserving();
    });
  }
});

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

    $('#bucket_details_dialog .delete_button').bind('click', function (e) {
      e.preventDefault();
      BucketsSection.startRemovingBucket();
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
  showBucket: function (uri) {
    ThePage.ensureSection('buckets');
    // we don't care about value, but we care if it's defined
    DAO.cells.currentPoolDetailsCell.getValue(function () {
      BucketsSection.withBucket(uri, function (bucketDetails) {
        BucketsSection.currentlyShownBucket = bucketDetails;
        var initValues = _.extend({}, bucketDetails, bucketDetails.settingsCell.value);
        var dialog = new BucketDetailsDialog(initValues, false);
        dialog.startDialog();
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
    var totals = DAO.cells.currentPoolDetails.value.storageTotals;
    if (totals.ram.quotaTotal == totals.ram.quotaUsed || totals.hdd.quotaTotal == totals.hdd.quotaUsed) {
      alert('TODO: No free quota left!')
      return;
    }
    var initValues = {uri: '/pools/default/buckets',
                      quota: {ram: totals.ram.quotaTotal - totals.ram.quotaUsed,
                              hdd: totals.hdd.quotaTotal - totals.hdd.quotaUsed},
                      replicaNumber: 1}
    var dialog = new BucketDetailsDialog(initValues, true);
    dialog.startDialog();
  },
  // TODO: currently inaccessible from UI
  startRemovingBucket: function () {
    if (!this.currentlyShownBucket)
      return;

    $('#bucket_details_dialog').addClass('overlayed');
    $('#bucket_remove_dialog .bucket_name').text(this.currentlyShownBucket.name);
    showDialog('bucket_remove_dialog', {
      onHide: function () {
        $('#bucket_details_dialog').removeClass('overlayed');
      }
    });
  },
  // TODO: currently inaccessible from UI
  removeCurrentBucket: function () {
    var self = this;

    var bucket = self.currentlyShownBucket;
    if (!bucket)
      return;

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
      hideDialog('bucket_details_dialog');
      hideDialog('bucket_remove_dialog');
    }
  }
};

configureActionHashParam("editBucket", $m(BucketsSection, 'showBucket'));

$(function () {
  var oldIsSasl;
  var dialog = $('#bucket_details_dialog')
  dialog.observePotentialChanges(function () {
    var isSasl = $('#bucket_details_sasl_selected')[0].checked;
    if (oldIsSasl != null && isSasl == oldIsSasl)
      return;
    oldIsSasl = isSasl;

    setBoolAttribute(dialog.find('.for-sasl-password-input input'), 'disabled', !isSasl);
    setBoolAttribute(dialog.find('.for-proxy-port input'), 'disabled', isSasl);
  });
});
