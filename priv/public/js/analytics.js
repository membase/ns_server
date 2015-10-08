/**
   Copyright 2015 Couchbase, Inc.

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
var StatsModel = {};

(function (self) {
  // starts future.get with given ajaxOptions and arranges invocation
  // of 'body' with value or if future is cancelled invocation of body
  // with 'cancelledValue'.
  //
  // NOTE: this is not normal future as normal futures deliver values
  // to cell, but this one 'delivers' values to given function 'body'.
  function getCPS(ajaxOptions, cancelledValue, body) {
    // this wrapper calls 'body' instead of delivering value to it's
    // cell
    var futureWrapper = future.wrap(function (ignoredDataCallback, startGet) {
      return startGet(body);
    });
    var async = future.get(ajaxOptions, undefined, undefined, futureWrapper);
    async.cancel = (function (realCancel) {
      return function () {
        if (realCancel) {
          realCancel.call(this);
        }
        body(cancelledValue);
      }
    })(async.cancel);
    // we need any cell here to satisfy our not yet perfect API
    async.start(new Cell());
    return async;
  }

  function createSamplesFuture(opts, bufferDepth) {
    var cancelMark = {};
    var mark404 = {};

    function doGet(data, body) {
      if (mainAsync.cancelled) {
        return body(cancelMark);
      }

      function onCancel() {
        if (async) {
          async.cancel();
        }
      }
      function unbind() {
        $(mainAsync).unbind('cancelled', onCancel);
      }
      $(mainAsync).bind('cancelled', onCancel);

      var async;
      return async = getCPS({url: '/_uistats', data: data, missingValue: mark404}, cancelMark, function (value, status, xhr) {
        unbind();
        if (value !== cancelMark && value !== mark404) {
          var date = xhr.getResponseHeader('date');
          value.serverDate = parseHTTPDate(date).valueOf();
          value.clientDate = (new Date()).valueOf();
        }
        body(value, status, xhr);
      });
    }

    var dataCallback;

    var mainAsync = future(function (_dataCallback) {
      dataCallback = _dataCallback;
      loop();
    });
    mainAsync.cancel = function () {
      $(this).trigger("cancelled");
    };

    var extraOpts = {};
    var prevValue;

    return mainAsync;

    function loop(deliverValue) {
      doGet(_.extend({}, opts, extraOpts), onLoopData);
    }

    function onLoopData(value) {
      if (value === mark404) {
        return;
      }
      if (prevValue) {
        value = maybeApplyDelta(prevValue, value);
      }
      if (!dataCallback.continuing(value)) {
        return;
      }
      prevValue = value;
      if (value.lastTStamp) {
        extraOpts = {haveTStamp: JSON.stringify(value.lastTStamp)};
      }
      if (!('nextReqAfter' in value)) {
        BUG();
      }
      setTimeout(loop, value.nextReqAfter);
    }

    function restoreOpsBlock(prevSamples, samples, keepCount) {
      var prevTS = prevSamples.timestamp;
      if (samples.timestamp && samples.timestamp.length == 0) {
        // server was unable to return any data for this "kind" of
        // stats
        if (prevSamples && prevSamples.timestamp && prevSamples.timestamp.length > 0) {
          return prevSamples;
        }
        return samples;
      }
      if (prevTS == undefined ||
          prevTS.length == 0 ||
          prevTS[prevTS.length-1] != samples.timestamp[0]) {
        return samples;
      }
      var newSamples = {};
      for (var keyName in samples) {
        var ps = prevSamples[keyName];
        if (!ps) {
          ps = [];
          ps.length = keepCount;
        }
        newSamples[keyName] = ps.concat(samples[keyName].slice(1)).slice(-keepCount);
      }
      return newSamples;
    }

    function maybeApplyDelta(prevValue, value) {
      var stats = value.stats;
      var prevStats = prevValue.stats || {};
      for (var kind in stats) {
        var newSamples = restoreOpsBlock(prevStats[kind],
                                         stats[kind],
                                         value.samplesCount + bufferDepth);
        stats[kind] = newSamples;
      }
      return value;
    }
  }

  var statsBucketURL = self.statsBucketURL = new StringHashFragmentCell("statsBucket");
  var statsHostname = self.statsHostname = new StringHashFragmentCell("statsHostname");
  var statsStatName = self.statsStatName = new StringHashFragmentCell("statsStatName");

  self.selectedGraphNameCell = new StringHashFragmentCell("graph");

  self.configurationExtra = new Cell();

  self.smallGraphSelectionCellCell = Cell.compute(function (v) {
    return v.need(self.displayingSpecificStatsCell) ? self.statsHostname : self.selectedGraphNameCell;
  });

  // contains bucket details of statsBucketURL bucket (or default if there are no such bucket)
  var statsBucketDetails = self.statsBucketDetails = Cell.compute(function (v) {
    var uri = v(statsBucketURL);
    var buckets = v.need(DAL.cells.bucketsListCell);
    var rv;
    if (uri !== undefined) {
      rv = _.detect(buckets, function (info) {return info.uri === uri});
    } else {
      rv = _.detect(buckets, function (info) {return info.name === "default"}) || buckets[0];
    }
    return rv;
  }).name("statsBucketDetails");

  var statsOptionsCell = self.statsOptionsCell = (new Cell()).name("statsOptionsCell");
  statsOptionsCell.setValue({});
  _.extend(statsOptionsCell, {
    update: function (options) {
      this.modifyValue(_.bind($.extend, $, {}), options);
    },
    equality: _.isEqual
  });

  var samplesBufferDepthRAW = new StringHashFragmentCell("statsBufferDepth");
  self.samplesBufferDepth = Cell.computeEager(function (v) {
    return v(samplesBufferDepthRAW) || 1;
  });

  var zoomLevel;
  (function () {
    var slider = $("#js_date_slider").slider({
      orientation: "vertical",
      range: "min",
      min: 1,
      max: 6,
      value: 6,
      step: 1,
      slide: function(event, ui) {
        var dateSwitchers = $("#js_date_slider_container .js_click");
        dateSwitchers.eq(dateSwitchers.length - ui.value).trigger('click');
      }
    });

    zoomLevel = (new LinkSwitchCell('zoom', {
      firstItemIsDefault: true
    })).name("zoomLevel");

    _.each('minute hour day week month year'.split(' '), function (name) {
      zoomLevel.addItem('js_zoom_' + name, name);
    });

    zoomLevel.finalizeBuilding();

    zoomLevel.subscribeValue(function (zoomLevel) {
      var z = $('#js_zoom_' + zoomLevel);
      slider.slider('value', 6 - z.index());
      self.statsOptionsCell.update({
        zoom: zoomLevel
      });
    });
  })();

  self.rawStatsCell = Cell.compute(function (v) {
    if (v.need(DAL.cells.mode) != "analytics") {
      return;
    }
    var options = v.need(statsOptionsCell);
    var node;
    var bucket = v.need(statsBucketDetails).name;
    var data = _.extend({bucket: bucket}, options);
    var statName = v(statsStatName);
    if (statName) {
      data.statName = statName;
    } else if ((node = v(statsHostname))) {
      // we don't send node it we're dealing with "specific stats" and
      // we're careful to depend on statsHostname cell _only_ we're
      // willing to send node.
      data.node = node;
    }
    var bufferDepth = v.need(self.samplesBufferDepth);
    return createSamplesFuture(data, bufferDepth);
  });

  self.displayingSpecificStatsCell = Cell.compute(function (v) {
    return !!(v.need(self.rawStatsCell).specificStatName);
  });

  self.directoryURLCell = Cell.compute(function (v) {
    return v.need(self.rawStatsCell).directory.url;
  });
  self.directoryURLCell.equality = function (a, b) {return a === b;};

  self.directoryValueCell = Cell.compute(function (v) {
    return v.need(self.rawStatsCell).directory.value;
  });
  self.directoryValueCell.equality = _.isEqual;

  self.directoryCell = Cell.compute(function (v) {
    var url = v.need(self.directoryURLCell);
    if (url) {
      return future.get({url: url});
    }
    return v.need(self.directoryValueCell);
  });

  self.specificStatTitleCell = Cell.compute(function (v) {
    return v.need(self.rawStatsCell).directory.origTitle;
  });

  self.infosCell = Cell.needing(self.directoryCell).compute(function (v, statDesc) {
    statDesc = JSON.parse(JSON.stringify(statDesc)); // this makes deep copy of statDesc

    var infos = [];
    infos.byName = {};

    var statItems = [];
    var blockIDs = [];

    var hadServerResources = false;
    if (statDesc.blocks[0].serverResources) {
      // We want it last so that default stat name (which is first
      // statItems entry) is not from ServerResourcesBlock
      hadServerResources = true;
      statDesc.blocks = statDesc.blocks.slice(1).concat([statDesc.blocks[0]]);
    }
    _.each(statDesc.blocks, function (aBlock) {
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
    // and now make ServerResourcesBlock first for rendering
    if (hadServerResources) {
      statDesc.blocks.unshift(statDesc.blocks.pop());
    }
    _.each(statItems, function (item) {
      infos.push(item);
      infos.byName[item.name] = item;
    });
    infos.blockIDs = blockIDs;

    var infosByTitle = _.groupBy(infos, "title");

    _.each(infos, function (statInfo) {
      if (statInfo.missing || statInfo.bigTitle) {
        return;
      }
      var title = statInfo.title;
      var homonyms = infosByTitle[title];
      if (homonyms.length == 1) {
        return;
      }
      var sameBlock = _.any(homonyms, function (otherInfo) {
        return otherInfo !== statInfo && otherInfo.blockId === statInfo.blockId;
      });
      var blockInfo = _.detect(statDesc.blocks, function (blockCand) {
        return blockCand.id === statInfo.blockId;
      });
      if (!blockInfo) {
        BUG();
      }
      if (sameBlock && blockInfo.columns) {
        var idx = _.indexOf(blockInfo.stats, statInfo);
        if (idx < 0) {
          BUG();
        }
        statInfo.bigTitle = blockInfo.columns[idx % 4] + ' ' + statInfo.title;
      } else {
        statInfo.bigTitle = (blockInfo.bigTitlePrefix || blockInfo.blockName) + ' ' + statInfo.title;
      }
    });

    return {statDesc: statDesc, infos: infos};
  });

  self.statsDescInfoCell = Cell.needing(self.infosCell).compute(function (v, infos) {
    return infos.statDesc;
  }).name("statsDescInfoCell");

  self.graphsConfigurationCell = Cell.compute(function (v) {
    var selectedGraphName = v(v.need(self.smallGraphSelectionCellCell));
    var stats = v.need(self.rawStatsCell);
    var selected;

    var infos = v.need(self.infosCell).infos;
    if (selectedGraphName && (selectedGraphName in infos.byName)) {
      selected = infos.byName[selectedGraphName];
    } else {
      selected = infos[0];
    }

    var auxTS = {};

    var samples = _.clone(stats.stats[stats.mainStatsBlock]);
    _.each(stats.stats, function (subSamples, subName) {
      if (subName === stats.mainStatsBlock) {
        return;
      }
      var timestamps = subSamples.timestamp;
      for (var k in subSamples) {
        if (k == "timestamp") {
          continue;
        }
        samples[k] = subSamples[k];
        auxTS[k] = timestamps;
      }
    });

    if (!samples[selected.name]) {
      selected = _.detect(infos, function (info) {return samples[info.name];}) || selected;
    }

    return {
      interval: stats.interval,
      zoomLevel: v.need(zoomLevel),
      selected: selected,
      samples: samples,
      timestamp: samples.timestamp,
      auxTimestamps: auxTS,
      serverDate: stats.serverDate,
      clientDate: stats.clientDate,
      infos: infos,
      extra: v(self.configurationExtra)
    };
  });

  self.statsNodesCell = Cell.compute(function (v) {
    return _.filter(v.need(DAL.cells.serversCell).active, function (node) {
      return node.clusterMembership !== 'inactiveFailed' && node.status !== 'unhealthy';
    });
  });

  self.hotKeysCell = Cell.computeEager(function (v) {
    if (!v(self.statsBucketDetails)) {
      // this deals with "no buckets at all" case for us
      return [];
    }
    return v.need(self.rawStatsCell).hot_keys || [];
  });
  self.hotKeysCell.equality = _.isEqual;

  Cell.autonameCells(self);
})(StatsModel);

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

  function renderSmallGraph(jq, options) {
    function reqOpt(name) {
      var rv = options[name];
      if (rv === undefined)
        throw new Error("missing option: " + name);
      return rv;
    }
    var data = reqOpt('data');
    var now = reqOpt('now');
    var plotSeries = buildPlotSeries(data,
                                     reqOpt('timestamp'),
                                     reqOpt('breakInterval'),
                                     reqOpt('timeOffset')).plotSeries;

    var lastY = data[data.length-1];
    var maxString = isNaN(lastY) ? 'N/A' : ViewHelpers.formatQuantity(lastY, options.isBytes ? 1024 : 1000);
    queuedUpdates.push(function () {
      jq.find('#js_small_graph_value').text(maxString);
    });
    if (queuedUpdates.length == 1) {
      setTimeout(flushQueuedUpdate, 0);
    }

    var color = reqOpt('isSelected') ? '#e2f1f9' : '#d95e28';

    var yaxis = {min:0, ticks:0, autoscaleMargin: 0.04}

    if (options.maxY)
      yaxis.max = options.maxY;

    $.plot(jq.find('#js_small_graph_block'),
           _.map(plotSeries, function (plotData) {
             return {color: color,
                     shadowSize: shadowSize,
                     data: plotData};
           }),
           {xaxis: {ticks:0,
                    autoscaleMargin: 0.04,
                    min: now - reqOpt('zoomMillis'),
                    max: now},
            yaxis: yaxis,
            grid: {show:false}});
  }

  global.renderSmallGraph = renderSmallGraph;
})(this);

var GraphsWidget = mkClass({
  initialize: function (largeGraphJQ, smallGraphsContainerJQ, descCell, configurationCell, isBucketAvailableCell) {
    this.largeGraphJQ = largeGraphJQ;
    this.smallGraphsContainerJQ = smallGraphsContainerJQ;

    this.drawnDesc = this.drawnConfiguration = {};
    Cell.subscribeMultipleValues($m(this, 'renderAll'), descCell, configurationCell, isBucketAvailableCell);
  },
  // renderAll (and subscribeMultipleValues) exist to strictly order renderStatsBlock w.r.t. updateGraphs
  renderAll: function (desc, configuration, isBucketAvailable) {
    if (this.drawnDesc !== desc) {
      this.renderStatsBlock(desc);
      this.drawnDesc = desc;
    }
    if (this.drawnConfiguration !== configuration) {
      this.updateGraphs(configuration);
      this.drawnConfiguration = configuration;
    }

    if (!isBucketAvailable) {
      this.unrenderNothing();
      this.largeGraphJQ.html('');
      this.smallGraphsContainerJQ.html('');
      $('#js_analytics .js_current-graph-name').text('');
      $('#js_analytics .js_current-graph-desc').text('');
    }
  },
  unrenderNothing: function () {
    if (this.spinners) {
      _.each(this.spinners, function (s) {s.remove()});
      this.spinners = null;
    }
  },
  renderNothing: function () {
    if (this.spinners) {
      return;
    }
    this.spinners = [
      overlayWithSpinner(this.largeGraphJQ, undefined, undefined, 1)
    ];
    this.smallGraphsContainerJQ.find('#js_small_graph_value').text('?')
  },
  renderStatsBlock: function (descValue) {
    if (!descValue) {
      this.smallGraphsContainerJQ.html('');
      this.renderNothing();
      return;
    }
    this.unrenderNothing();
    renderTemplate('js_new_stats_block', descValue, this.smallGraphsContainerJQ[0]);
    $(this).trigger('menelaus.graphs-widget.rendered-stats-block');
  },
  zoomToSeconds: {
    minute: 60,
    hour: 3600,
    day: 86400,
    week: 691200,
    month: 2678400,
    year: 31622400
  },
  forceNextRendering: function () {
    this.lastCompletedTimestamp = undefined;
  },
  updateGraphs: function (configuration) {
    var self = this;

    if (!configuration) {
      self.lastCompletedTimestamp = undefined;
      return self.renderNothing();
    }

    self.unrenderNothing();

    var nowTStamp = (new Date()).valueOf();
    if (self.lastCompletedTimestamp && nowTStamp - self.lastCompletedTimestamp < 200) {
      // skip this sample as we're too slow
      return;
    }

    var stats = configuration.samples;

    var timeOffset = configuration.clientDate - configuration.serverDate;

    var zoomMillis = (self.zoomToSeconds[configuration.zoomLevel] || 60) * 1000;
    var selected = configuration.selected;
    var now = (new Date()).valueOf();
    if (configuration.interval < 2000) {
      now -= StatsModel.samplesBufferDepth.value * 1000;
    }

    maybeReloadAppDueToLeak();

    var auxTS = configuration.auxTimestamps || {};

    plotStatGraph(self.largeGraphJQ, stats[selected.name], auxTS[selected.name] || configuration.timestamp, {
      color: '#1d88ad',
      verticalMargin: 1.02,
      fixedTimeWidth: zoomMillis,
      timeOffset: timeOffset,
      lastSampleTime: now,
      breakInterval: configuration.interval * 2.5,
      maxY: configuration.infos.byName[selected.name].maxY,
      isBytes: configuration.selected.isBytes
    });

    try {
      var visibleBlockIDs = {};
      _.each($(_.map(configuration.infos.blockIDs, $i)).filter(":has(.js_stats:visible)"), function (e) {
        visibleBlockIDs[e.id] = e;
      });
    } catch (e) {
      debugger
      throw e;
    }

    _.each(configuration.infos, function (statInfo) {
      if (!visibleBlockIDs[statInfo.blockId]) {
        return;
      }
      var statName = statInfo.name;
      var graphContainer = $($i(statInfo.id));
      if (graphContainer.length == 0) {
        return;
      }
      renderSmallGraph(graphContainer, {
        data: stats[statName] || [],
        breakInterval: configuration.interval * 2.5,
        timeOffset: timeOffset,
        now: now,
        zoomMillis: zoomMillis,
        isSelected: selected.name == statName,
        timestamp: auxTS[statName] || configuration.timestamp,
        maxY: configuration.infos.byName[statName].maxY,
        isBytes: statInfo.isBytes
      });
    });

    self.lastCompletedTimestamp = (new Date()).valueOf();

    $(self).trigger('menelaus.graphs-widget.rendered-graphs');
  }
});

var AnalyticsSection = {
  onKeyStats: function (hotKeys) {
    renderTemplate('js_top_keys', _.map(hotKeys, function (e) {
      return $.extend({}, e, {total: 0 + e.gets + e.misses});
    }));
  },
  init: function () {
    var self = this;

    StatsModel.hotKeysCell.subscribeValue($m(self, 'onKeyStats'));
    prepareTemplateForCell('js_top_keys', StatsModel.hotKeysCell);
    StatsModel.displayingSpecificStatsCell.subscribeValue(function (displayingSpecificStats) {
      $('#js_top_keys_block').toggle(!displayingSpecificStats);
    });

    $('#js_analytics .js_block-expander').live('click', function () {
      // this forces configuration refresh and graphs redraw
      self.widget.forceNextRendering();
      StatsModel.configurationExtra.setValue({});
    });

    IOCenter.staleness.subscribeValue(function (stale) {
      $('#js_stats-period-container')[stale ? 'hide' : 'show']();
      $('#js_analytics .js_staleness-notice')[stale ? 'show' : 'hide']();
    });

    (function () {
      var cell = Cell.compute(function (v) {
        var mode = v.need(DAL.cells.mode);
        if (mode != 'analytics') {
          return;
        }

        var allBuckets = v.need(DAL.cells.bucketsListCell);
        var selectedBucket = v(StatsModel.statsBucketDetails);
        return {list: _.map(allBuckets, function (info) {return [info.uri, info.name]}),
                selected: selectedBucket && selectedBucket.uri};
      });
      $('#js_analytics_buckets_select').bindListCell(cell, {
        onChange: function (e, newValue) {
          StatsModel.statsBucketURL.setValue(newValue);
        }
      });
    })();

    (function () {
      var cell = Cell.compute(function (v) {
        var mode = v.need(DAL.cells.mode);
        if (mode != 'analytics') {
          return;
        }

        var allNodes = v(StatsModel.statsNodesCell);
        var statsHostname = v(StatsModel.statsHostname);

        var list;
        if (allNodes) {
          list = _.map(allNodes, function (srv) {
            var name = ViewHelpers.maybeStripPort(srv.hostname, allNodes);
            return [srv.hostname, name];
          });
          // natural sort by full hostname (which includes port number)
          list.sort(mkComparatorByProp(0, naturalSort));
          list.unshift(['', 'All Server Nodes (' + allNodes.length + ')' ]);
        }

        return {list: list, selected: statsHostname};
      });
      $('#js_analytics_servers_select').bindListCell(cell, {
        onChange: function (e, newValue) {
          StatsModel.statsHostname.setValue(newValue || undefined);
        }
      });
    })();

    self.widget = new GraphsWidget(
      $('#js_analytics_main_graph'),
      $('#js_stats_container'),
      StatsModel.statsDescInfoCell,
      StatsModel.graphsConfigurationCell,
      DAL.cells.isBucketsAvailableCell);

    Cell.needing(StatsModel.graphsConfigurationCell).compute(function (v, configuration) {
      return configuration.timestamp.length == 0;
    }).subscribeValue(function (missingSamples) {
      $('#js_stats-period-container').toggleClass('dynamic_missing-samples', !!missingSamples);
    });
    Cell.needing(StatsModel.graphsConfigurationCell).compute(function (v, configuration) {
      var zoomMillis = GraphsWidget.prototype.zoomToSeconds[configuration.zoomLevel] * 1000;
      return Math.ceil(Math.min(zoomMillis, configuration.serverDate - configuration.timestamp[0]) / 1000);
    }).subscribeValue(function (visibleSeconds) {
      $('#js_stats_visible_period').text(isNaN(visibleSeconds) ? '?' : formatUptime(visibleSeconds));
    });

    (function () {
      var selectionCell;
      StatsModel.smallGraphSelectionCellCell.subscribeValue(function (cell) {
        selectionCell = cell;
      });

      $(".js_analytics-small-graph").live("click", function (e) {
        // don't intercept right arrow clicks
        if ($(e.target).is(".js_right-arrow, .js_right-arrow *")) {
          return;
        }
        e.preventDefault();
        var graphParam = this.getAttribute('data-graph');
        if (!graphParam) {
          debugger
          throw new Error("shouldn't happen");
        }
        if (!selectionCell) {
          return;
        }
        selectionCell.setValue(graphParam);
        self.widget.forceNextRendering();
      });
    })();

    (function () {
      function handler() {
        var val = effectiveSelected.value;
        val = val && val.name;
        $('.js_analytics-small-graph.dynamic_selected').removeClass('dynamic_selected');
        if (!val) {
          return;
        }
        $(_.filter($('.js_analytics-small-graph[data-graph]'), function (el) {
          return String(el.getAttribute('data-graph')) === val;
        })).addClass('dynamic_selected');
      }
      var effectiveSelected = Cell.compute(function (v) {return v.need(StatsModel.graphsConfigurationCell).selected});
      effectiveSelected.subscribeValue(handler);
      $(self.widget).bind('menelaus.graphs-widget.rendered-stats-block', handler);
    })();

    $(self.widget).bind('menelaus.graphs-widget.rendered-graphs', function () {
      var graph = StatsModel.graphsConfigurationCell.value.selected;
      $('#js_analytics .js_current-graph-name').text(graph.bigTitle || graph.title);
      $('#js_analytics .js_current-graph-desc').text(graph.desc);
    });

    $(self.widget).bind('menelaus.graphs-widget.rendered-stats-block', function () {
      $('#js_stats_container').hide();
      _.each($('.js_analytics-small-graph:not(.dynamic_dim)'), function (e) {
        e = $(e);
        var graphParam = e.attr('data-graph');
        if (!graphParam) {
          debugger
          throw new Error("shouldn't happen");
        }
        var ul = e.find('.js_right-arrow .js_inner').need(1);

        var params = {sec: 'analytics', statsBucket: StatsModel.statsBucketDetails.value.uri};
        var aInner;

        if (!StatsModel.displayingSpecificStatsCell.value) {
          params.statsStatName = graphParam;
          aInner = "show by server";
        } else {
          params.graph = StatsModel.statsStatName.value;
          params.statsHostname = graphParam.slice(1);
          aInner = "show this server";
        }

        ul[0].appendChild(jst.analyticsRightArrow(aInner, params));
      });
      $('#js_stats_container').show();
    });

    StatsModel.displayingSpecificStatsCell.subscribeValue(function (displayingSpecificStats) {
      displayingSpecificStats = !!displayingSpecificStats;
      $('#js_analytics .js_when-normal-stats').toggle(!displayingSpecificStats);
      $('#js_analytics .js_when-specific-stats').toggle(displayingSpecificStats);
    });

    StatsModel.specificStatTitleCell.subscribeValue(function (val) {
      var text = val || '?';
      $('.js_specific-stat-description').text(text);
    });
  },
  onLeave: function () {
    setHashFragmentParam("zoom", undefined);
    StatsModel.statsHostname.setValue(undefined);
    StatsModel.statsBucketURL.setValue(undefined);
    StatsModel.selectedGraphNameCell.setValue(undefined);
    StatsModel.statsStatName.setValue(undefined);
  },
  onEnter: function () {
  }
};
