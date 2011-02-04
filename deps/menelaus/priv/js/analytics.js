var SamplesRestorer = mkClass({
  initialize: function (url, options, keepSamplesCount) {
    this.birthTime = (new Date()).valueOf();
    this.url = url;
    this.options = options;
    this.keepSamplesCount = keepSamplesCount;
    this.valueTransformer = $m(this, 'transformData');
    this.grabToken = mkTokenBucket(2, 10, 4);
  },
  getRequestData: function () {
    var data = _.extend({}, this.options);
    _.each(data.nonQ, function (n) {
      delete data[n];
    });
    if (this.prevTimestamp !== undefined)
      data['haveTStamp'] = this.prevTimestamp;
    return data;
  },
  transformData: function (value) {
    var op = value.op;
    var samples = op.samples;
    this.samplesInterval = op.interval;
    this.prevTimestamp = op.lastTStamp || this.prevTimestamp;

    if (!op.tstampParam) {
      if (samples.timestamp.length > 0)
        this.prevSamples = samples;
      else
        op.samples = this.prevSamples;
      return value;
    }

    var prevSamples = this.prevSamples;
    var newSamples = {};

    for (var keyName in samples) {
      newSamples[keyName] = prevSamples[keyName].concat(samples[keyName].slice(1)).slice(-this.keepSamplesCount);
    }

    this.prevSamples = op.samples = newSamples;

    return value;
  },
  nextSampleTime: function () {
    var now = (new Date()).valueOf();
    if (this.samplesInterval === undefined)
      return now;
    if (this.samplesInterval < 2000)
      return now;
    return now + Math.min(this.samplesInterval/2, 60000);
  }
});

;(function () {
  var statsBucketURL = this.statsBucketURL = new StringHashFragmentCell("statsBucket");

  var targetCell = this.currentStatTargetCell = new Cell(function (poolDetails, mode) {
    if (mode != 'analytics')
      return;

    if (!this.bucketURL)
      return poolDetails;

    var bucket = BucketsSection.findBucket(this.bucketURL);
    if (bucket)
      return bucket;
    return future.get({url: this.bucketURL, stdErrorMarker: true});
  }, {bucketURL: statsBucketURL,
      poolDetails: this.currentPoolDetailsCell,
      mode: this.mode});

  var StatsArgsCell = new Cell(function (target) {
    return {url: target.stats.uri};
  }, {target: targetCell});

  var statsOptionsCell = new Cell();
  statsOptionsCell.setValue({nonQ: ['keysInterval', 'nonQ'], resampleForUI: '1'});
  _.extend(statsOptionsCell, {
    update: function (options) {
      this.modifyValue(_.bind($.extend, $, {}), options);
    },
    equality: _.isEqual
  });

  var samplesBufferDepthRAW = new StringHashFragmentCell("statsBufferDepth");
  var samplesBufferDepth = Cell.compute(function (v) {
    return v(samplesBufferDepthRAW) || 1;
  });

  var samplesRestorerCell = Cell.computeEager(function (v) {
    var target = v.need(targetCell);
    var options = v.need(statsOptionsCell);
    var keepCount = 60;
    if (options.zoom == "minute") {
      keepCount = v.need(samplesBufferDepth) + 60;
    }
    return new SamplesRestorer(target.stats.uri, options, keepCount);
  });

  var statsCell = Cell.mkCaching(function (samplesRestorer) {
    var self = this.self;

    if (!samplesRestorer.grabToken()) {
      console.log("stats request prevented by token bucket filter");
      _.defer(function () {self.recalculateAfterDelay(2000)});
      return Cell.STANDARD_ERROR_MARK;
    }

    function futureWrapper(body, options) {
      function wrappedBody(dataCallback) {
        function wrappedDataCallback(value, status, xhr) {
          if (value !== Cell.STANDARD_ERROR_MARK) {
            var date = xhr.getResponseHeader('date');
            value = samplesRestorer.valueTransformer(value);
            value.serverDate = parseHTTPDate(date).valueOf();
            value.clientDate = (new Date()).valueOf();
          }
          dataCallback(value);
          if (value === Cell.STANDARD_ERROR_MARK) {
            self.recalculateAt(samplesRestorer.nextSampleTime());
          }
        }

        body(wrappedDataCallback);
      }
      return future(wrappedBody, options);
    }

    return future.get({
      url: samplesRestorer.url,
      data: samplesRestorer.getRequestData(),
      onError: function (dataCallback) {
        dataCallback(Cell.STANDARD_ERROR_MARK);
      }
    }, undefined, undefined, futureWrapper);
  },{samplesRestorer: samplesRestorerCell,
     options: statsOptionsCell,
     target: targetCell});

  statsCell.target.setRecalculateTime = function () {
    var samplesRestorer = this.context.samplesRestorer.value;
    if (!samplesRestorer)
      return;
    var at = samplesRestorer.nextSampleTime();
    this.recalculateAt(at);
  }
  statsCell.setRecalculateTime = $m(statsCell.target, 'setRecalculateTime');

  _.extend(DAO.cells, {
    stats: statsCell,
    statsOptions: statsOptionsCell,
    currentPoolDetails: DAO.cells.currentPoolDetailsCell,
    samplesBufferDepth: samplesBufferDepth
  });
}).call(DAO.cells);

var maybeReloadAppDueToLeak = (function () {
  var counter = 300;

  return function () {
    if (!window.G_vmlCanvasManager)
      return;

    if (!--counter)
      reloadPage();
  };
})();

function renderSmallGraph(jq, ops, statName, isSelected, zoomMillis, timeOffset, options) {
  var data = ops.samples[statName] || [];
  var plotSeries = buildPlotSeries(data,
                                   ops.samples.timestamp,
                                   ops.interval * 2.5,
                                   timeOffset).plotSeries;

  var lastY = data[data.length-1];
  var now = (new Date()).valueOf();
  if (ops.interval < 2000)
    now -= DAO.cells.samplesBufferDepth.value * 1000;

  var maxString = isNaN(lastY) ? '?' : ViewHelpers.formatQuantity(lastY, '', 1000);
  jq.find('.small_graph_label > .value').text(maxString);

  var color = isSelected ? '#e2f1f9' : '#d95e28';

  var yaxis = {min:0, ticks:0, autoscaleMargin: 0.04}

  if (options.rate)
    yaxis.max = 100;

  $.plotSafe(jq.find('.small_graph_block'),
             _.map(plotSeries, function (plotData) {
               return {color: color,
                       data: plotData};
             }),
             {xaxis: {ticks:0,
                      autoscaleMargin: 0.04,
                      min: now - zoomMillis,
                      max: now},
              yaxis: yaxis,
              grid: {show:false}});
}

var KnownPersistentStats = [];
var KnownCacheStats =  [];

var StatGraphs = {
  selected: null,
  recognizedStatsPersistent: null,
  recognizedStatsCache:  null,
  recognizedStats: null,
  visibleStats: [],
  visibleStatsIsDirty: true,
  spinners: [],
  preventUpdatesCounter: 0,
  freeze: function () {
    this.preventUpdatesCounter++;
  },
  thaw: function () {
    this.preventUpdatesCounter--;
    if (!this.preventUpdatesCounter) {
      this.update();
    }
  },
  freezeIfIE: function () {
    if (!window.G_vmlCanvasManager)
      return _.identity;

    this.freeze();
    return _.bind(this.thaw, this);
  },
  findGraphArea: function (statName) {
    var father;
    if (this.nowIsPersistent == null) {
      father = $([]);
    } else if (this.nowIsPersistent) {
      father = $('#stats_nav_persistent_container');
    } else {
      father = $('#stats_nav_cache_container');
    }
    return father.find('.analytics_graph_' + statName);
  },
  renderNothing: function () {
    var self = this;
    if (self.spinners.length)
      return;

    var main = $('#analytics_main_graph')
    self.spinners.push(overlayWithSpinner(main));

    _.each(self.effectivelyVisibleStats || [], function (statName) {
      var area = self.findGraphArea(statName);
      self.spinners.push(overlayWithSpinner(area));
    });

    $('.stats_visible_period').text('?');
  },
  updateVisibleStats: function () {
    var self = this;

    self.recognizedStats = (self.nowIsPersistent) ? self.recognizedStatsPersistent : self.recognizedStatsCache;
    $('#stats_nav_cache_container, #configure_cache_stats_items_container')[self.nowIsPersistent ? 'hide' : 'show']();
    $('#stats_nav_persistent_container, #configure_persistent_stats_items_container')[self.nowIsPersistent ? 'show' : 'hide']();

    self.effectivelyVisibleStats = _.clone(self.recognizedStats);
  },
  zoomToSeconds: {
    minute: 60,
    hour: 3600,
    day: 86400,
    week: 691200,
    month: 2678400,
    year: 31622400
  },
  findGraphOptions: function (name) {
    var infos = KnownCacheStats;
    if (this.nowIsPersistent)
      infos = KnownPersistentStats;
    return _.detect(infos, function (i) {return i[0] == name;})[2] || {};
  },
  doUpdate: function () {
    var self = this;

    if (self.preventUpdatesCounter)
      return;

    var cell = DAO.cells.stats;
    var stats = cell.value;
    if (!stats)
      return self.renderNothing();
    var op = stats = stats.op;
    if (!stats)
      return self.renderNothing();
    stats = stats.samples;

    var timeOffset = (cell.value.clientDate - cell.value.serverDate);

    _.each(self.spinners, function (s) {
      s.remove();
    });
    self.spinners = [];

    var main = $('#analytics_main_graph');

    if (!self.recognizedStats || self.nowIsPersistent != op.isPersistent) {
      self.visibleStatsIsDirty = true;
      self.nowIsPersistent = op.isPersistent;
    }

    if (self.visibleStatsIsDirty) {
      self.updateVisibleStats();

      // _.each(self.recognizedStats, function (name) {
      //   var op = _.include(self.effectivelyVisibleStats, name) ? 'show' : 'hide';
      //   var area = self.findGraphArea(name);
      //   area[op]();
      // });
      self.visibleStatsIsDirty = false;
    }

    if (!stats) {
      stats = {timestamp: []};
      (function (stats) {
        _.each(self.recognizedStats, function (name) {
          stats[name] = [];
        });
      })(stats);
      op.samples = stats;
    }

    var zoomMillis = (self.zoomToSeconds[DAO.cells.zoomLevel.value] || 60) * 1000;
    var selected = self.selected.value;
    var now = (new Date()).valueOf();
    if (op.interval < 2000)
      now -= DAO.cells.samplesBufferDepth.value * 1000;

    maybeReloadAppDueToLeak();
    plotStatGraph(main, stats, selected, {
      color: '#1d88ad',
      verticalMargin: 1.02,
      fixedTimeWidth: zoomMillis,
      timeOffset: timeOffset,
      lastSampleTime: now,
      breakInterval: op.interval * 2.5,
      rate: self.findGraphOptions(selected).rate
    });
    $('.stats-period-container').toggleClass('missing-samples', !stats[selected] || !stats[selected].length);
    var visibleSeconds = Math.ceil(Math.min(zoomMillis, now - stats.timestamp[0]) / 1000);
    $('.stats_visible_period').text(isNaN(visibleSeconds) ? '?' : formatUptime(visibleSeconds));

    _.each(self.effectivelyVisibleStats, function (statName) {
      var area = self.findGraphArea(statName);
      var options = self.findGraphOptions(statName);
      renderSmallGraph(area, op, statName, selected == statName, zoomMillis, timeOffset, options);
    });
  },
  updateRealtime: function () {
    if (this.refreshTimeoutId && this.renderingRealtime)
      return;

    if (this.refreshTimeoutId) {
      clearInterval(this.refreshTimeoutId);
      this.refreshTimeoutId = undefined;
    }

    this.renderingRealtime = true;

    this.refreshTimeoutId = setInterval($m(this, 'doUpdate'), 1000);

    this.doUpdate();
  },
  update: function () {
    var cell = DAO.cells.stats;
    var stats = cell.value;

    cell.setRecalculateTime();

    if (stats && stats.op && stats.op.interval < 2000)
      return this.updateRealtime();

    this.renderingRealtime = false;

    this.doUpdate();

    // this makes sure that we're refreshing graph even when no data arrives
    if (this.refreshTimeoutId) {
      clearInterval(this.refreshTimeoutId);
      this.refreshTimeoutId = undefined;
    }

    this.refreshTimeoutId = setInterval($m(this, 'update'), 60000);
  },
  configureStats: function () {
    var self = this;

    self.prepareConfigureDialog();

    var dialog = $('#analytics_settings_dialog');
    var values = {};

    if (!self.recognizedStats)
      return;

    _.each(self.recognizedStats, function (name) {
      values[name] = _.include(self.effectivelyVisibleStats, name);
    });
    setFormValues(dialog, values);

    var observer = dialog.observePotentialChanges(watcher);

    var hiddenVisibleStats = _.reject(self.visibleStats, function (name) {
      return _.include(self.effectivelyVisibleStats, name);
    });

    var oldChecked;
    function watcher(e) {
      var checked = $.map(dialog.find('input:checked'), function (el, idx) {
        return el.getAttribute('name');
      }).sort();

      if (_.isEqual(checked, oldChecked))
        return;
      oldChecked = checked;

      self.visibleStats = checked = hiddenVisibleStats.concat(checked).sort();
      $.cookie('vs', checked.join(','));
      self.visibleStatsIsDirty = true;
      self.update();
    }

    var thaw = StatGraphs.freezeIfIE();
    showDialog('analytics_settings_dialog', {
      onHide: function () {
        thaw();
        observer.stopObserving();
      }
    });
  },
  prepareConfigureDialog: function () {
    var knownStats;
    if (this.nowIsPersistent) {
      knownStats = KnownPersistentStats;
    } else {
      knownStats = KnownCacheStats;
    }

    var leftCount = (knownStats.length + 1) >> 1;
    var shuffledPairs = new Array(knownStats.length);
    var i,k;
    for (i = 0, k = 0; i < knownStats.length; i += 2, k++) {
      shuffledPairs[i] = knownStats[k];
      shuffledPairs[i+1] = knownStats[leftCount + k];
    }
    shuffledPairs.length = knownStats.length;

    renderTemplate('configure_stats_items',
                   _.map(shuffledPairs, function (pair) {
                     var name = pair[0];
                     var ar = pair[1].split("\n", 2);
                     if (ar.length == 1)
                       ar[1] = ar[0];
                     return {
                       name: name,
                       'short': ar[0],
                       full: ar[1]
                     };
                   }));
  },
  init: function () {
    $('.stats-block-expander').live('click', function () {
      $(this).parents('.graph_nav').first().toggleClass('closed');
    });
    ;(function () {
      var data =
        {blocks: [
          {blockName: "MEMCACHED",
           stats: [
             {name: "ops", desc: "Operations per sec."},
             {name: "hit_ratio", desc: "Hit ratio (%)"},
             {name: "mem_used", desc: "Memory bytes used"},
             {name: "curr_items", desc: "Items count"},
             {name: "evictions", desc: "RAM evictions per sec."},
             {name: "cmd_set", desc: "Sets per sec."},
             {name: "cmd_get", desc: "Gets per sec."},
             {name: "bytes_written", desc: "Network bytes TX per sec."},
             {name: "bytes_read", desc: "Network bytes RX per sec."},
             {name: "get_hits", desc: "Get hits per sec."},
             {name: "delete_hits", desc: "Delete hits per sec."},
             {name: "incr_hits", desc: "Incr hits per sec."},
             {name: "decr_hits", desc: "Decr hits per sec."},
             {name: "delete_misses", desc: "Delete misses per sec."},
             {name: "decr_misses", desc: "Decr misses per sec."},
             {name: "get_misses", desc: "Get Misses per sec."},
             {name: "incr_misses", desc: "Incr misses per sec."},
             {name: "curr_connections", desc: "Connections co."},
             {name: "cas_hits", desc: "CAS hits per sec."},
             {name: "cas_badval", desc: "CAS badval per sec."},
             {name: "cas_misses", desc: "CAS misses per sec."}]}]};
      var statItems = _.reduce(_.pluck(data.blocks, 'stats'), [], function (acc, stats) {
        return acc.concat(stats);
      });
      _.each(statItems, function (item) {
        if (!item.name)
          return;
        KnownCacheStats.push([item.name, item.desc]);
      });
      StatGraphs.recognizedStatsCache = _.pluck(KnownCacheStats, 0);
      renderTemplate('new_stats_block', data, $i('stats_nav_cache_container'));
    })();
    // renderTemplate('stats_nav', KnownCacheStats, $i('stats_nav_cache_container'));
    ;(function () {
      var data = {
        blocks: [
          {
            blockName: "PERFORMANCE",
            isPerf: true,
            stats: [
              // Total
              {desc: "ops per second", name: "ops"},
              {desc: "direct per second", name: "ops_direct", missing: true},
              {desc: "moxi per second", name: "ops_moxi", missing: true},
              {desc: "average object size", name: "avg_item_size", missing: true}, // need total size _including_ size on disk
              // Read
              {desc: "cache hit %", name: "ep_cache_hit_rate"}, //?
              {desc: "hit latency", name: "hit_latency", missing: true}, //?
              {desc: "cache miss %", name: "ep_cache_miss_rate"}, //?
              {desc: "miss latency", name: "miss_latency", missing: true}, //?
              // Write
              {desc: "creates per second", name: "ep_ops_create"}, // TODO: aggregate it in ns_server
              {desc: "updates per second", name: "ep_ops_update"}, // ?
              {desc: "write latency", name: "ep_write_latency", missing: true}, // ?
              {desc: "back-offs per second", name: "ep_tap_total_queue_backoff"} //,
              // Moxi
              // {desc: "local %", name: "", missing: true},
              // {desc: "local latency", name: "", missing: true},
              // {desc: "proxy %", name: "", missing: true},
              // {desc: "proxy latency", name: "", missing: true}
            ]
          }, {
            blockName: "vBUCKET RESOURCES",
            withtotal: true,
            stats: [
              {desc: "active vBuckets (count)", name: "vb_active_num"},
              {desc: "replica vBuckets (count)", name: "vb_replica_num"},
              {desc: "pending vBuckets (count)", name: "vb_pending_num"},
              {desc: "total vBuckets (count)", name: "ep_vb_total"},
              // --
              {desc: "# objects", name: "curr_items"},
              {desc: "# objects", name: "vb_replica_curr_items"},
              {desc: "# objects", name: "vb_pending_curr_items"},
              {desc: "# objects", name: "curr_items_tot"},
              // --
              {desc: "% memory resident", name: "vb_active_resident_items_ratio"},
              {desc: "% memory resident", name: "vb_replica_resident_items_ratio"},
              {desc: "% memory resident", name: "vb_pending_resident_items_ratio"},
              {desc: "% memory resident", name: "ep_resident_items_rate"},
              // --
              {desc: "new per second", name: "vb_active_ops_create"},
              {desc: "new per second", name: "vb_replica_ops_create"},
              {desc: "new per second", name: "vb_pending_ops_create"},
              {desc: "new per second", name: "ep_ops_create"},
              // --
              // TODO: this is missing in current ep-engine
              {desc: "eject per second", name: "", missing: true},
              {desc: "eject per second", name: "", missing: true},
              {desc: "eject per second", name: "", missing: true},
              {desc: "eject per second", name: "evictions"},
              // --
              {desc: "K-V memory", name: "vb_active_itm_memory"},
              {desc: "K-V memory", name: "vb_replica_itm_memory"},
              {desc: "K-V memory", name: "vb_pending_itm_memory"},
              {desc: "K-V memory", name: "ep_kv_size"},
              // --
              {desc: "metadata memory", name: "vb_active_ht_memory"},
              {desc: "metadata memory", name: "vb_replica_ht_memory"},
              {desc: "metadata memory", name: "vb_pending_ht_memory"},
              {desc: "metadata memory", name: "ep_ht_memory"} //,
              // --
              // TODO: this is missing in current ep-engine
              // {desc: "disk used", name: "", missing: true},
              // {desc: "disk used", name: "", missing: true},
              // {desc: "disk used", name: "", missing: true},
              // {desc: "disk used", name: "", missing: true}
            ]
          }, {
            blockName: "DISK QUEUES",
            withtotal: true,
            stats: [
              // {desc: "Active", name: ""},
              // {desc: "Replica", name: ""},
              // {desc: "Pending", name: ""},
              // {desc: "Total", name: ""},

              {desc: "active items", name: "vb_active_queue_pending"},
              {desc: "replica items", name: "vb_replica_queue_pending"},
              {desc: "pending items", name: "vb_pending_queue_pending"},
              {desc: "total items", name: "curr_items_tot"},
              // --
              {desc: "queue memory", name: "vb_active_queue_memory"},
              {desc: "queue memory", name: "vb_replica_queue_memory"},
              {desc: "queue memory", name: "vb_pending_queue_memory"},
              {desc: "queue memory", name: "vb_total_queue_memory"},
              // --
              {desc: "fill rate", name: "vb_active_queue_fill"},
              {desc: "fill rate", name: "vb_replica_queue_fill"},
              {desc: "fill rate", name: "vb_pending_queue_fill"},
              {desc: "fill rate", name: "vb_total_queue_fill"},
              // --
              {desc: "drain rate", name: "vb_active_queue_drain"},
              {desc: "drain rate", name: "vb_replica_queue_drain"},
              {desc: "drain rate", name: "vb_pending_queue_drain"},
              {desc: "drain rate", name: "vb_total_queue_drain"},
              // --
              {desc: "average age", name: "vb_avg_active_queue_age"},
              {desc: "average age", name: "vb_avg_replica_queue_age"},
              {desc: "average age", name: "vb_avg_pending_queue_age"},
              {desc: "average age", name: "vb_avg_total_queue_age"}
            ]
          }, {
            blockName: "TAP QUEUES",
            withtotal: true,
            stats: [
              // {desc: "Replica", name: ""},
              // {desc: "Rebalance", name: ""},
              // {desc: "User", name: ""},
              // {desc: "Total", name: ""},

              {desc: "# replica tap senders", name: "ep_tap_replica_count"},
              {desc: "# rebalance tap senders", name: "ep_tap_rebalance_count"},
              {desc: "# user tap senders", name: "ep_tap_user_count"},
              {desc: "# total tap senders", name: "ep_tap_total_count"},
              // --
              {desc: "# items", name: "ep_tap_replica_qlen"},
              {desc: "# items", name: "ep_tap_rebalance_qlen"},
              {desc: "# items", name: "ep_tap_user_qlen"},
              {desc: "# items", name: "ep_tap_total_qlen"},
              // --
              {desc: "fill rate", name: "ep_tap_replica_queue_fill"},
              {desc: "fill rate", name: "ep_tap_rebalance_queue_fill"},
              {desc: "fill rate", name: "ep_tap_user_queue_fill"},
              {desc: "fill rate", name: "ep_tap_total_queue_fill"},
              // --
              {desc: "drain rate", name: "ep_tap_replica_queue_drain"},
              {desc: "drain rate", name: "ep_tap_rebalance_queue_drain"},
              {desc: "drain rate", name: "ep_tap_user_queue_drain"},
              {desc: "drain rate", name: "ep_tap_total_queue_drain"},
              // --
              {desc: "back-off rate", name: "ep_tap_replica_queue_backoff"},
              {desc: "back-off rate", name: "ep_tap_rebalance_queue_backoff"},
              {desc: "back-off rate", name: "ep_tap_user_queue_backoff"},
              {desc: "back-off rate", name: "ep_tap_total_queue_backoff"},
              // --
              {desc: "# backfill remaining", name: "ep_tap_replica_queue_backfillremaining"},
              {desc: "# backfill remaining", name: "ep_tap_rebalance_queue_backfillremaining"},
              {desc: "# backfill remaining", name: "ep_tap_user_queue_backfillremaining"},
              {desc: "# backfill remaining", name: "ep_tap_total_queue_backfillremaining"},
              // --
              {desc: "# remaining on disk", name: "ep_tap_replica_queue_itemondisk"},
              {desc: "# remaining on disk", name: "ep_tap_rebalance_queue_itemondisk"},
              {desc: "# remaining on disk", name: "ep_tap_user_queue_itemondisk"},
              {desc: "# remaining on disk", name: "ep_tap_total_queue_itemondisk"}
              // --
            ]
          }
        ]
      };
      var statItems = _.reduce(_.pluck(data.blocks, 'stats'), [], function (acc, stats) {
        return acc.concat(stats);
      });
      _.each(statItems, function (item) {
        if (!item.name)
          return;
        KnownPersistentStats.push([item.name, item.desc]);
      });
      StatGraphs.recognizedStatsPersistent = _.pluck(KnownPersistentStats, 0);
      renderTemplate('new_stats_block', data, $i('stats_nav_persistent_container'));
    })();

    var self = this;

    self.selected = new LinkClassSwitchCell('graph', {
      bindMethod: 'bind',
      linkSelector: '.analytics-small-graph',
      firstItemIsDefault: true}),

    DAO.cells.stats.subscribeAny($m(this, 'update'));

    var selected = self.selected;

    var t;
    _.each(_.uniq(self.recognizedStatsCache.concat(self.recognizedStatsPersistent)), function (statName) {
      var area = $('.analytics_graph_' + statName);
      if (!area.length) {
        return;
      }
      // area.hide();
      if (!t)
        t = area;
      else
        t = t.add(area);
      selected.addItem('analytics_graph_' + statName, statName);
    });

    selected.subscribe($m(self, 'update'));
    selected.finalizeBuilding();

    t.bind('mouseenter', mkHoverHandler('show'));
    t.bind('mouseleave', mkHoverHandler('hide'));

    function mkHoverHandler(method) {
      return function (event) {
        var hoverRect = $(event.currentTarget).data('hover-rect');
        if (!hoverRect)
          return;
        hoverRect[method]();
      }
    }

    var visibleStatsCookie = $.cookie('vs');
    if (visibleStatsCookie == null) {
      visibleStatsCookie = _.uniq(_.pluck(_.select(KnownPersistentStats, function (tuple) {
        return (tuple[2] || {}).isDefault;
      }), 0).concat(self.recognizedStatsCache.slice(0,4))).join(',');
    }

    self.visibleStats = visibleStatsCookie.split(',').sort();
  }
}

var AnalyticsSection = {
  onKeyStats: function (cell) {
    renderTemplate('top_keys', $.map(cell.value.hot_keys, function (e) {
      return $.extend({}, e, {total: 0 + e.gets + e.misses});
    }));
    $('#top_keys_container table tr:has(td):odd').addClass('even');
  },
  init: function () {
    DAO.cells.zoomLevel = new LinkSwitchCell('zoom', {
      firstItemIsDefault: true
    });

    _.each('minute hour day week month year'.split(' '), function (name) {
      DAO.cells.zoomLevel.addItem('zoom_' + name, name)
    });

    DAO.cells.zoomLevel.finalizeBuilding();

    DAO.cells.zoomLevel.subscribeValue(function (zoomLevel) {
      DAO.cells.statsOptions.update({
        zoom: zoomLevel
      });
    });

    DAO.cells.stats.subscribe($m(this, 'onKeyStats'));
    prepareTemplateForCell('top_keys', DAO.cells.currentStatTargetCell);

    StatGraphs.init();

    DAO.cells.currentStatTargetCell.subscribe(function (cell) {
      var value = cell.value.name;
      var names = $('.stat_target_name');
      names.text(value);
    });

    var statsStaleness = (function (meta) {
      return Cell.compute(function (v) {
        return !!(v.need(meta).stale);
      });
    })(DAO.cells.stats.ensureMetaCell());

    statsStaleness.subscribeValue(function (stale) {
      $('.stats-period-container')[stale ? 'hide' : 'show']();
      $('#analytics .staleness-notice')[stale ? 'show' : 'hide']();
    });
  },
  visitBucket: function (bucketURL) {
    if (DAO.cells.mode.value != 'analytics')
      ThePage.gotoSection('analytics');
    DAO.cells.statsBucketURL.setValue(bucketURL);
  },
  onLeave: function () {
    setHashFragmentParam('graph', undefined);
    DAO.cells.statsBucketURL.setValue(undefined);
  },
  onEnter: function () {
    StatGraphs.update();
  },
  // called when we're already in this section and user tries to
  // navigate to this section
  navClick: function () {
    this.onLeave(); // reset state
  }
};
