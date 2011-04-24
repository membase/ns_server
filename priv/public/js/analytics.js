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
      rv.propagateMeta = undefined;
      rv.metaCell = (function () {
        var dependencyCell = new Cell();
        var cell = Cell.compute(function (v) {
          return v.need(v.need(dependencyCell));
        });
        cell.dependencyCell = dependencyCell;
        return cell;
      })();
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
      dataCallback.cell.metaCell.dependencyCell.setValue(rawStatsCell.ensureMetaCell());
    }

    function handleStaticStats(rawStats) {
      if (rawStats === Cell.STANDARD_ERROR_MARK) {
        rawStatsCell.metaCell.setValueAttr(true, 'stale');
      } else {
        rawStatsCell.metaCell.setValueAttr(false, 'stale');
        dataCallback.continuing(rawStats);
        rawStatsCell.recalculateAfterDelay(Math.min(interval/2, 60000));
      }
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
      return withStatsTransformer.get({url: statsURL, data: data, stdErrorMarker: true});
    });

    dataCallback.cell.metaCell.dependencyCell.setValue(rawStatsCell.ensureMetaCell());

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
      if (rawStats === Cell.STANDARD_ERROR_MARK) {
        rawStatsCell.metaCell.setValueAttr(true, 'stale');
        return;
      }
      rawStatsCell.metaCell.setValueAttr(false, 'stale');

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
  var statsHostname = this.statsHostname = new StringHashFragmentCell("statsHostname");

  var statsBucketDetails = this.statsBucketDetails = Cell.compute(function (v) {
    var uri = v(statsBucketURL);
    var buckets = v.need(DAL.cells.bucketsListCell);
    var rv;
    if (uri !== undefined) {
      rv = _.detect(buckets, function (info) {return info.uri === uri});
    } else {
      rv = _.detect(buckets, function (info) {return info.name === "default"}) || buckets[0];
    }
    return rv;
  });

  var statsNodesCell = this.statsNodesCell = Cell.compute(function (v) {
    // TODO: introduce direct attr for that
    return future.get({url: v.need(statsBucketDetails).uri + "/nodes"});
  });

  var targetCell = this.currentStatTargetCell = Cell.compute(function (v) {
    var mode = v.need(DAL.cells.mode);
    if (mode !== 'analytics') {
      return;
    }

    var hostname = v(statsHostname);
    if (!hostname) {
      return v.need(statsBucketDetails);
    }

    var nodes = v.need(statsNodesCell);
    var nodeInfo = _.detect(nodes.servers, function (info) {return info.hostname === hostname});
    if (!nodeInfo) {
      return v.need(statsBucketDetails);
    }

    return nodeInfo;
  });

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

  var shadowSize = 3;

  if (window.G_vmlCanvasManager) {
    shadowSize = 0;
  }

  function renderSmallGraph(jq, ops, statName, isSelected, zoomMillis, timeOffset, options) {
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

    if (options.maxY)
      yaxis.max = options.maxY;

    $.plot(jq.find('.small_graph_block'),
           _.map(plotSeries, function (plotData) {
             return {color: color,
                     shadowSize: shadowSize,
                     data: plotData};
           }),
           {xaxis: {ticks:0,
                    autoscaleMargin: 0.04,
                    min: now - zoomMillis,
                    max: now},
            yaxis: yaxis,
            grid: {show:false}});
  }

  global.renderSmallGraph = renderSmallGraph;
})(this);

var PersistentStatInfos = []
PersistentStatInfos.byName = {};

var CacheStatInfos = [];
CacheStatInfos.byName = {};

var StatGraphs = {
  selected: null,
  spinners: [],
  renderNothing: function () {
    var self = this;
    if (self.spinners.length)
      return;

    var main = $('#analytics_main_graph')
    self.spinners.push(overlayWithSpinner(main));

    var section = $('#analytics');
    section.find('.small_graph_block').empty();
    section.find('.small_graph_label .value').html('?');

    $('.stats_visible_period').text('?');
  },
  zoomToSeconds: {
    minute: 60,
    hour: 3600,
    day: 86400,
    week: 691200,
    month: 2678400,
    year: 31622400
  },
  lastCompletedTimestamp: undefined,
  update: function () {
    var self = this;

    var configuration = self.graphsConfigurationCell.value;
    if (!configuration) {
      self.lastCompletedTimestamp = undefined;
      return self.renderNothing();
    }

    var nowTStamp = (new Date()).valueOf();
    if (self.lastCompletedTimestamp && nowTStamp - self.lastCompletedTimestamp < 200) {
      // skip this sample as we're too slow
      return;
    }

    var op = configuration.stats.op;
    var stats = op.samples;

    var timeOffset = configuration.stats.clientDate - configuration.stats.serverDate;

    _.each(self.spinners, function (s) {
      s.remove();
    });
    self.spinners = [];

    var main = $('#analytics_main_graph');
    var isPersistent = op.isPersistent;

    $('#stats_nav_cache_container, #configure_cache_stats_items_container')[isPersistent ? 'hide' : 'show']();
    $('#stats_nav_persistent_container, #configure_persistent_stats_items_container')[isPersistent ? 'show' : 'hide']();

    if (!stats) {
      stats = {timestamp: []};
      _.each(_.keys(configuration.infos), function (name) {
        stats[name] = [];
      });
      op = _.clone(op);
      op.samples = stats;
    }

    var zoomMillis = (self.zoomToSeconds[DAL.cells.zoomLevel.value] || 60) * 1000;
    var selected = configuration.selected;
    $('.analytics_graph_main h2').html(selected.desc);
    var now = (new Date()).valueOf();
    if (op.interval < 2000) {
      now -= DAL.cells.samplesBufferDepth.value * 1000;
    }

    maybeReloadAppDueToLeak();

    plotStatGraph(main, stats[selected.name], stats.timestamp, {
      color: '#1d88ad',
      verticalMargin: 1.02,
      fixedTimeWidth: zoomMillis,
      timeOffset: timeOffset,
      lastSampleTime: now,
      breakInterval: op.interval * 2.5,
      maxY: configuration.infos.byName[selected.name].maxY
    });

    $('.stats-period-container').toggleClass('missing-samples', !stats[selected.name] || !stats[selected.name].length);
    var visibleSeconds = Math.ceil(Math.min(zoomMillis, now - stats.timestamp[0]) / 1000);
    $('.stats_visible_period').text(isNaN(visibleSeconds) ? '?' : formatUptime(visibleSeconds));

    var visibleBlockIDs = {};
    _.each($(_.map(configuration.infos.blockIDs, $i)).filter(":has(.stats:visible)"), function (e) {
      visibleBlockIDs[e.id] = e;
    });

    _.each(configuration.infos, function (statInfo) {
      if (!visibleBlockIDs[statInfo.blockId]) {
        return;
      }
      var statName = statInfo.name;
      var area = $($i(statInfo.id));
      var options = {
        maxY: configuration.infos.byName[statName].maxY
      };
      renderSmallGraph(area, op, statName, selected.name == statName,
                       zoomMillis, timeOffset, options);
    });

    self.lastCompletedTimestamp = (new Date()).valueOf();
  },
  init: function () {
    $('.stats-block-expander').live('click', function () {
      $(this).closest('.graph_nav').toggleClass('closed');
      // this forces configuration refresh and graphs redraw
      self.graphsConfigurationCell.invalidate();
      self.lastCompletedTimestamp = undefined;
    });

    function initStatsCategory(infos, containerEl, data) {
      var statItems = [];
      var blockIDs = [];
      _.each(data.blocks, function (aBlock) {
        var blockName = aBlock.blockName;
        aBlock.id = _.uniqueId("GB");
        blockIDs.push(aBlock.id);
        var stats = aBlock.stats;
        statItems = statItems.concat(stats);
        _.each(stats, function (statInfo) {
          statInfo.id = _.uniqueId("G");
          statInfo.blockId = aBlock.id;
        });
      });
      _.each(statItems, function (item) {
        infos.push(item);
        infos.byName[item.name] = item;
      });
      infos.blockIDs = blockIDs;
      renderTemplate('new_stats_block', data, containerEl);
    }

    initStatsCategory(
      CacheStatInfos, $i('stats_nav_cache_container'),
      {blocks: [
        {blockName: "SERVER RESOURCES",
         extraCSSClasses: "server_resources",
         stats: [
           {name: "mem_actual_free", desc: "Mem actual free"},
           {name: "mem_free", desc: "Mem free"},
           {name: "cpu_utilization_rate", desc: "CPU %"},
           {name: "swap_used", desc: "swap_used"}]},
        {blockName: "MEMCACHED",
         stats: [
           {name: "ops", desc: "Operations per sec.", 'default': true},
           {name: "hit_ratio", desc: "Hit ratio (%)", maxY: 100},
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
           {name: "cas_misses", desc: "CAS misses per sec."}]}]});

    initStatsCategory(
      PersistentStatInfos, $i('stats_nav_persistent_container'),
      {blocks: [
        {blockName: "SERVER RESOURCES",
         extraCSSClasses: "server_resources",
         stats: [
           {name: "mem_actual_free", desc: "free memory"},
           // {name: "mem_free", desc: "Mem free"},
           {name: "cpu_utilization_rate", desc: "CPU utilization %", maxY: 100},
           {name: "swap_used", desc: "swap usage"}]},
        {
          blockName: "PERFORMANCE",
          columns: ['Totals', 'Read', 'Write', 'Moxi'],
          stats: [
            // column 1
            // aggregated from gets, sets, incr, decr, delete
            // Total ops. Likely doesn't include other types of commands
            {desc: "ops per second", name: "ops", 'default': true},
            // Read (cmd_get - ep_bg_fetched) / cmd_get * 100
            {desc: "cache hit %", name: "ep_cache_hit_rate", maxY: 100},
            {desc: "creates per second", name: "ep_ops_create"},
            {desc: "local %", name: "proxy_local_ratio"},
            // column 2
            // Total ops - proxy_cmd_count
            {desc: "direct per second", name: "direct_ops"},
            // Read
            {desc: "hit latency", name: "hit_latency", missing: true}, //?
            // Write
            {desc: "updates per second", name: "ep_ops_update"},
            // Moxi
            {desc: "local latency", name: "proxy_local_latency"},
            // column 3
            // Total ops through server-side moxi
            {desc: "moxi per second", name: "proxy_cmd_count"},
            // Read
            {desc: "miss latency", name: "miss_latency", missing: true}, //?
            // Write
            {desc: "write latency", name: "ep_write_latency", missing: true}, // ?
            // Moxi
            {desc: "proxy %", name: "proxy_ratio", maxY: 100},
            // column 4
            // (Total) average object size)
            {desc: "average object size", name: "avg_item_size", missing: true}, // need total size _including_ size on disk
            // Read
            {desc: "disk reads", name: "ep_bg_fetched"},
            // Write
            {desc: "back-offs per second", name: "ep_tap_total_queue_backoff"},
            // Moxie
            {desc: "proxy latency", name: "proxy_latency"}
          ]
        }, {
          blockName: "vBUCKET RESOURCES",
          extraCSSClasses: 'withtotal closed',
          columns: ['Active', 'Replica', 'Pending', 'Total'],
          stats: [
            {desc: "active vBuckets", name: "vb_active_num"},
            {desc: "replica vBuckets", name: "vb_replica_num"},
            {desc: "pending vBuckets", name: "vb_pending_num"},
            {desc: "total vBuckets", name: "ep_vb_total"},
            // --
            {desc: "active items", name: "curr_items"},
            {desc: "replica items", name: "vb_replica_curr_items"},
            {desc: "pending items", name: "vb_pending_curr_items"},
            {desc: "total items", name: "curr_items_tot"},
            // --
            {desc: "% resident items", name: "vb_active_resident_items_ratio", maxY: 100},
            {desc: "% resident items", name: "vb_replica_resident_items_ratio", maxY: 100},
            {desc: "% resident items", name: "vb_pending_resident_items_ratio", maxY: 100},
            {desc: "% resident items", name: "ep_resident_items_rate", maxY: 100},
            // --
            {desc: "new items per sec", name: "vb_active_ops_create"},
            {desc: "new items per sec", name: "vb_replica_ops_create"},
            {desc: "new items per sec", name: "vb_pending_ops_create", missing: true},
            {desc: "new items per sec", name: "ep_ops_create"},
            // --
            {desc: "ejections per sec", name: "vb_active_eject"},
            {desc: "ejections per sec", name: "vb_replica_eject"},
            {desc: "ejections per sec", name: "vb_pending_eject"},
            {desc: "ejections per sec", name: "ep_num_value_ejects"},
            // --
            {desc: "user data in RAM", name: "vb_active_itm_memory"},
            {desc: "user data in RAM", name: "vb_replica_itm_memory"},
            {desc: "user data in RAM", name: "vb_pending_itm_memory"},
            {desc: "user data in RAM", name: "ep_kv_size"},
            // --
            {desc: "metadata in RAM", name: "vb_active_ht_memory"},
            {desc: "metadata in RAM", name: "vb_replica_ht_memory"},
            {desc: "metadata in RAM", name: "vb_pending_ht_memory"},
            {desc: "metadata in RAM", name: "ep_ht_memory"} //,
            // --
            // TODO: this is missing in current ep-engine
            // {desc: "disk used", name: "", missing: true},
            // {desc: "disk used", name: "", missing: true},
            // {desc: "disk used", name: "", missing: true},
            // {desc: "disk used", name: "", missing: true}
          ]
        }, {
          blockName: "DISK QUEUES",
          extraCSSClasses: 'withtotal closed',
          columns: ['Active', 'Replica', 'Pending', 'Total'],
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
          extraCSSClasses: 'withtotal closed',
          columns: ['Replication', 'Rebalance', 'Clients', 'Total'],
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
      ]});

    var self = this;

    self.selected = new LinkClassSwitchCell('graph', {
      bindMethod: 'bind',
      linkSelector: '.analytics-small-graph'});

    var selected = self.selected;

    var t;
    _.each(PersistentStatInfos.concat(CacheStatInfos), function (statInfo) {
      var statName = statInfo.name;
      var area = $($i(statInfo.id));
      if (!area.length) {
        throw new Error("BUG");
      }
      if (!t) {
        t = area;
      } else {
        t = t.add(area);
      }
      selected.addItem('analytics_graph_' + statName, statName, statInfo['default']);
    });

    selected.finalizeBuilding();

    self.graphsConfigurationCell = Cell.compute(function (v) {
      var selectedStatName = v.need(self.selected);
      var stats = v.need(DAL.cells.stats);
      var op = stats.op;
      if (!op) {
        return;
      }
      var infos = PersistentStatInfos;
      if (!op.isPersistent) {
        infos = CacheStatInfos;
      }
      if (!(selectedStatName in infos.byName) || !(selectedStatName in op.samples)) {
        selected = infos[0];
      } else {
        selected = infos.byName[selectedStatName];
      }

      return {
        selected: selected,
        stats: stats,
        infos: infos
      };
    });

    self.graphsConfigurationCell.subscribeAny($m(self, 'update'));

    Cell.compute(function (v) {
      var stats = v.need(self.graphsConfigurationCell).stats;
      var haveSystemStats = !!stats.op.samples.cpu_utilization_rate;
      return haveSystemStats;
    }).subscribeValue(function (haveSystemStats) {
      var container = $('#stats_nav_persistent_container, #stats_nav_cache_container').need(2);
      container[haveSystemStats ? 'addClass' : 'removeClass']('with_server_resources');
    });

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

    IOCenter.staleness.subscribeValue(function (stale) {
      $('.stats-period-container')[stale ? 'hide' : 'show']();
      $('#analytics .staleness-notice')[stale ? 'show' : 'hide']();
    });

    (function () {
      function onChange() {
        var newValue = $(this).val();
        DAL.cells.statsBucketURL.setValue(newValue);
      }

      var bucketsSelectArgs = Cell.compute(function (v) {
        var mode = v.need(DAL.cells.mode);
        if (mode != 'analytics') {
          return;
        }

        var allBuckets = v.need(DAL.cells.bucketsListCell);
        var selectedBucket = v.need(DAL.cells.statsBucketDetails);
        return {list: allBuckets,
                selected: selectedBucket};
      });

      bucketsSelectArgs.subscribeValue(function (args) {
        var select = $('#analytics_buckets_select').need(1);
        select.unbind('change', onChange);
        select.html('');

        if (!args) {
          return;
        }

        _.each(args.list, function (bucket) {
          var option = $("<option value='" + escapeHTML(bucket.uri) + "'>" + escapeHTML(bucket.name) + "</option>");
          option.boolAttr('selected', bucket.uri === args.selected.uri);
          select.append(option);
        });

        select.bind('change', onChange).combobox()
          .next('input').val(select.children(':selected').text());
      });
    })();

    (function () {
      function onChange() {
        var newValue = $(this).val();
        if (!newValue) {
          newValue = undefined;
        }
        DAL.cells.statsHostname.setValue(newValue);
      }

      var serversSelectArgs = Cell.compute(function (v) {
        var mode = v.need(DAL.cells.mode);
        if (mode != 'analytics') {
          return;
        }

        var allNodes = v.need(DAL.cells.statsNodesCell);
        var selectedNode;
        var statsHostname = v(DAL.cells.statsHostname);

        if (statsHostname) {
          selectedNode = v.need(DAL.cells.currentStatTargetCell);
        }

        return {list: allNodes.servers,
                selected: selectedNode};
      });

      serversSelectArgs.subscribeValue(function (args) {
        var select = $('#analytics_servers_select').need(1);

        select.unbind('change', onChange);
        select.html('');

        if (!args) {
          return;
        }

        var selectedName = args.selected ? args.selected.hostname : undefined;

        select.append("<option value='all'>All Server Nodes</option>");

        _.each(args.list, function (node) {
          var escapedHostname = escapeHTML(node.hostname);
          var option = $("<option value='" + escapedHostname + "'>" + escapedHostname + "</option>");
          option.boolAttr('selected', node.hostname === selectedName);
          select.append(option);
        });

        select.bind('change', onChange).combobox()
          .next('input').val(select.children(':selected').text());
      });
    })();
  },
  onLeave: function () {
    setHashFragmentParam('graph', undefined);
    DAL.cells.statsHostname.setValue(undefined);
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
