(function (global) {
  var withStatsTransformer = future.withEarlyTransformer(function (value, status, xhr) {
    var date = xhr.getResponseHeader('date');
    value.serverDate = parseHTTPDate(date).valueOf();
    value.clientDate = (new Date()).valueOf();
  });

  global.createSamplesRestorer = createSamplesRestorer;
  return;

  function createSamplesRestorer(statsURL, statsData) {
    var dataCallback;
    var interval;
    var bufferDepth;

    var rawStatsCell = Cell.compute(function (v) {
      return withStatsTransformer.get({url: statsURL, data: statsData});
    });

    return (function () {
      var rv = Cell.compute(function (v) {
        bufferDepth = v.need(DAL.cells.samplesBufferDepth);
        return future(function (cb) {
          dataCallback = cb;
          rawStatsCell.getValue(stage1);
        });
      });
      rv.detach = (function (orig) {
        return function () {
          console.log("detaching stats fetcher for:", statsURL, $.param(statsData));
          orig.apply(this, arguments)
        };
      })(rv.detach);
      rv.metaCell = rawStatsCell.ensureMetaCell();
      return rv;
    })();

    function stage1(rawStats) {
      interval = rawStats.op.interval;

      if (interval < 2000) {
        startRealTimeRestorer(rawStats, interval, dataCallback, bufferDepth, statsURL, statsData);
      } else {
        startStats();
        handleStaticStats(rawStats);
      }
    }

    function startStats() {
      rawStatsCell.subscribe(function () {
        handleStaticStats(rawStatsCell.value);
      });
      dataCallback.async.cancel = function () {
        rawStatsCell.detach();
      }
    }

    function handleStaticStats(rawStats) {
      dataCallback.continuing(rawStats);
      rawStatsCell.recalculateAfterDelay(Math.min(interval/2, 60000));
    }
  }

  function startRealTimeRestorer(rawStats, interval, dataCallback, bufferDepth,
                                 statsURL, statsData) {
    var prevSamples;
    var lastRaw;
    var prevTimestamp;
    var keepCount;
    var intervalId;
    var cancelled;

    // TODO: this is not 'pure' function, so we're breaking rules
    // slightly, but directly going through future is not best option
    // with current state of code
    var rawStatsCell = Cell.compute(function (v) {
      var data = _.extend({}, statsData);
      if (prevTimestamp !== undefined) {
        data['haveTStamp'] = prevTimestamp;
      }
      return withStatsTransformer.get({url: statsURL, data: data});
    });

    dataCallback.async.cancel = function () {
      cancelled = true;
      rawStatsCell.setValue(undefined);
      if (intervalId !== undefined) {
        cancelInterval(intervalId);
      }
    };

    keepCount = rawStats.op.samplesCount + bufferDepth;

    restoringSamples(rawStats);
    restoringSamplesTail();
    dataCallback.continuing(lastRaw);

    intervalId = setInterval(function () {
      dataCallback.continuing(_.clone(lastRaw));
    }, interval);

    return;

    function restoringSamples(rawStats) {
      var op = rawStats.op;
      var samples = op.samples;
      prevTimestamp = op.lastTStamp || prevTimestamp;

      if (!op.tstampParam) {
        if (samples.timestamp.length > 0) {
          prevSamples = samples;
        }
      } else {
        var newSamples = {};
        for (var keyName in samples) {
          newSamples[keyName] = prevSamples[keyName].concat(samples[keyName].slice(1)).slice(-keepCount);
        }
        prevSamples = newSamples;
      }

      lastRaw = _.clone(rawStats);
      lastRaw.op = _.clone(op);
      lastRaw.op.samples = prevSamples;
    }

    function restoringSamplesTail() {
      if (cancelled) {
        return;
      }
      rawStatsCell.invalidate(function () {
        restoringSamples(rawStatsCell.value);
        restoringSamplesTail();
      });
    }
  }
})(window);

;(function () {
  function diagCell(cell, name) {
    if (false) {
      cell.subscribeAny(function () {
        console.log("cell("+name+"):", cell.value);
      });
    }
  }

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

  diagCell(targetCell, "targetCell");

  var statsOptionsCell = new Cell();
  statsOptionsCell.setValue({nonQ: ['keysInterval', 'nonQ'], resampleForUI: '1'});
  _.extend(statsOptionsCell, {
    update: function (options) {
      this.modifyValue(_.bind($.extend, $, {}), options);
    },
    equality: _.isEqual
  });

  diagCell(statsOptionsCell, "statsOptionsCell");

  var statsURLCell = Cell.compute(function (v) {
    return v.need(targetCell).stats.uri;
  });

  var statsCellCell = Cell.compute(function (v) {
    var options = v.need(statsOptionsCell);
    var url = v.need(statsURLCell);

    var data = _.extend({}, options);
    _.each(data.nonQ, function (n) {
      delete data[n];
    });

    return createSamplesRestorer(url, data);
  });

  diagCell(statsURLCell, "statsURLCell");
  diagCell(statsCellCell, "statsCellCell");

  var statsCell = Cell.compute(function (v) {
    if (v.need(DAL.cells.mode) != 'analytics') {
      return;
    }
    return v.need(v.need(statsCellCell));
  });

  diagCell(statsCell, "statsCell");

  var samplesBufferDepthRAW = new StringHashFragmentCell("statsBufferDepth");
  var samplesBufferDepth = Cell.computeEager(function (v) {
    return v(samplesBufferDepthRAW) || 1;
  });

  _.extend(DAL.cells, {
    stats: statsCell,
    statsOptions: statsOptionsCell,
    currentPoolDetails: DAL.cells.currentPoolDetailsCell,
    samplesBufferDepth: samplesBufferDepth
  });
}).call(DAL.cells);

var maybeReloadAppDueToLeak = (function () {
  var counter = 300;

  return function () {
    if (!window.G_vmlCanvasManager)
      return;

    if (!--counter)
      reloadPage();
  };
})();


;(function (global) {

  var queuedUpdates = [];

  function flushQueuedUpdate() {
    var i = queuedUpdates.length;
    while (--i >= 0) {
      queuedUpdates[i]();
    }
    queuedUpdates.length = 0;
  }

  function renderSmallGraph(jq, ops, statName, isSelected, zoomMillis, timeOffset, options) {
    if (!jq.is(':visible')) {
      return;
    }
    var data = ops.samples[statName] || [];
    var plotSeries = buildPlotSeries(data,
                                     ops.samples.timestamp,
                                     ops.interval * 2.5,
                                     timeOffset).plotSeries;

    var lastY = data[data.length-1];
    var now = (new Date()).valueOf();
    if (ops.interval < 2000)
      now -= DAL.cells.samplesBufferDepth.value * 1000;

    var maxString = isNaN(lastY) ? '?' : ViewHelpers.formatQuantity(lastY, '', 1000);
    queuedUpdates.push(function () {
      jq.find('.small_graph_label > .value').text(maxString);
    });
    if (queuedUpdates.length == 1) {
      setTimeout(flushQueuedUpdate, 0);
    }

    var color = isSelected ? '#e2f1f9' : '#d95e28';

    var yaxis = {min:0, ticks:0, autoscaleMargin: 0.04}

    if (options.rate)
      yaxis.max = 100;

    _.each(jq.find('.small_graph_block'), function (item) {
      $.plotSafe($(item),
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
    });
  }

  global.renderSmallGraph = renderSmallGraph;
})(this);

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
  update: function () {
    var self = this;

    if (self.preventUpdatesCounter)
      return;

    var cell = DAL.cells.stats;
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

    var zoomMillis = (self.zoomToSeconds[DAL.cells.zoomLevel.value] || 60) * 1000;
    var selected = self.selected.value;
    var now = (new Date()).valueOf();
    if (op.interval < 2000)
      now -= DAL.cells.samplesBufferDepth.value * 1000;

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
             {name: "bytes_written", desc: "Net. bytes TX per sec."},
             {name: "bytes_read", desc: "Net. bytes RX per sec."},
             {name: "get_hits", desc: "Get hits per sec."},
             {name: "delete_hits", desc: "Delete hits per sec."},
             {name: "incr_hits", desc: "Incr hits per sec."},
             {name: "decr_hits", desc: "Decr hits per sec."},
             {name: "delete_misses", desc: "Delete misses per sec."},
             {name: "decr_misses", desc: "Decr misses per sec."},
             {name: "get_misses", desc: "Get Misses per sec."},
             {name: "incr_misses", desc: "Incr misses per sec."},
             {name: "curr_connections", desc: "Connections count."},
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
    ;(function () {
      var data = {
        blocks: [
          {
            blockName: "PERFORMANCE",
            isPerf: true,
            stats: [
              // Total
              // aggregated from gets, sets, incr, decr, delete
              // ops. Likely doesn't include other types of commands
              {desc: "ops per second", name: "ops"},
              // ops - proxy_cmd_count
              {desc: "direct per second", name: "direct_ops"},
              // total ops through server-side moxi
              {desc: "moxi per second", name: "proxy_cmd_count"},
              {desc: "average object size", name: "avg_item_size", missing: true}, // need total size _including_ size on disk
              // Read
              // (cmd_get - ep_bg_fetched) / cmd_get * 100
              {desc: "cache hit %", name: "ep_cache_hit_rate"},
              {desc: "hit latency", name: "hit_latency", missing: true}, //?
              {desc: "miss latency", name: "miss_latency", missing: true}, //?
              {desc: "disk reads", name: "ep_bg_fetched"},
              // Write
              {desc: "creates per second", name: "ep_ops_create"},
              {desc: "updates per second", name: "ep_ops_update"},
              {desc: "write latency", name: "ep_write_latency", missing: true}, // ?
              {desc: "back-offs per second", name: "ep_tap_total_queue_backoff"},
              // Moxi
              {desc: "local %", name: "proxy_local_ratio"},
              {desc: "local latency", name: "proxy_local_latency"},
              {desc: "proxy %", name: "proxy_ratio"},
              {desc: "proxy latency", name: "proxy_latency"}
            ]
          }, {
            blockName: "vBUCKET RESOURCES",
            withtotal: true,
            stats: [
              {desc: "vBuckets (count)", name: "vb_active_num"},
              {desc: "vBuckets (count)", name: "vb_replica_num"},
              {desc: "vBuckets (count)", name: "vb_pending_num"},
              {desc: "vBuckets (count)", name: "ep_vb_total"},
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
              {desc: "eject per second", name: "vb_active_eject"},
              {desc: "eject per second", name: "vb_replica_eject"},
              {desc: "eject per second", name: "vb_pending_eject"},
              {desc: "eject per second", name: "ep_num_value_ejects"},
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

              {desc: "items", name: "vb_active_queue_size"},
              {desc: "items", name: "vb_replica_queue_size"},
              {desc: "items", name: "vb_pending_queue_size"},
              {desc: "items", name: "ep_diskqueue_items"},
              // --
              {desc: "queue memory", name: "vb_active_queue_memory"},
              {desc: "queue memory", name: "vb_replica_queue_memory"},
              {desc: "queue memory", name: "vb_pending_queue_memory"},
              {desc: "queue memory", name: "ep_diskqueue_memory"},
              // --
              {desc: "fill rate", name: "vb_active_queue_fill"},
              {desc: "fill rate", name: "vb_replica_queue_fill"},
              {desc: "fill rate", name: "vb_pending_queue_fill"},
              {desc: "fill rate", name: "ep_diskqueue_fill"},
              // --
              {desc: "drain rate", name: "vb_active_queue_drain"},
              {desc: "drain rate", name: "vb_replica_queue_drain"},
              {desc: "drain rate", name: "vb_pending_queue_drain"},
              {desc: "drain rate", name: "ep_diskqueue_drain"},
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

              {desc: "# tap senders", name: "ep_tap_replica_count"},
              {desc: "# tap senders", name: "ep_tap_rebalance_count"},
              {desc: "# tap senders", name: "ep_tap_user_count"},
              {desc: "# tap senders", name: "ep_tap_total_count"},
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

    DAL.cells.stats.subscribeAny($m(self, 'update'));

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
    DAL.cells.zoomLevel = new LinkSwitchCell('zoom', {
      firstItemIsDefault: true
    });

    _.each('minute hour day week month year'.split(' '), function (name) {
      DAL.cells.zoomLevel.addItem('zoom_' + name, name)
    });

    DAL.cells.zoomLevel.finalizeBuilding();

    DAL.cells.zoomLevel.subscribeValue(function (zoomLevel) {
      DAL.cells.statsOptions.update({
        zoom: zoomLevel
      });
    });

    DAL.cells.stats.subscribe($m(this, 'onKeyStats'));
    prepareTemplateForCell('top_keys', DAL.cells.currentStatTargetCell);

    StatGraphs.init();

    DAL.cells.currentStatTargetCell.subscribe(function (cell) {
      var value = cell.value.name;
      var names = $('.stat_target_name');
      names.text(value);
    });

    var statsStaleness = (function (meta) {
      return Cell.compute(function (v) {
        return !!(v.need(meta).stale);
      });
    })(DAL.cells.stats.ensureMetaCell());

    statsStaleness.subscribeValue(function (stale) {
      $('.stats-period-container')[stale ? 'hide' : 'show']();
      $('#analytics .staleness-notice')[stale ? 'show' : 'hide']();
    });
  },
  visitBucket: function (bucketURL) {
    if (DAL.cells.mode.value != 'analytics')
      ThePage.gotoSection('analytics');
    DAL.cells.statsBucketURL.setValue(bucketURL);
  },
  onLeave: function () {
    setHashFragmentParam('graph', undefined);
    DAL.cells.statsBucketURL.setValue(undefined);
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
