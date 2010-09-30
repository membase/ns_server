var SamplesRestorer = mkClass({
  initialize: function (url, options) {
    this.birthTime = (new Date()).valueOf();
    this.url = url;
    this.options = options;
    this.valueTransformer = $m(this, 'transformData');
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
    this.prevTimestamp = op.lastTStamp;

    if (!op.tstampParam) {
      this.prevSamples = samples;
      return value;
    }

    var prevSamples = this.prevSamples;
    var newSamples = {};

    for (var keyName in samples) {
      newSamples[keyName] = prevSamples[keyName].concat(samples[keyName].slice(1)).slice(-60);
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
    return future.get({url: this.bucketURL});
  }).setSources({bucketURL: statsBucketURL,
                 poolDetails: this.currentPoolDetailsCell,
                 mode: this.mode});

  var StatsArgsCell = new Cell(function (target) {
    return {url: target.stats.uri};
  }).setSources({target: targetCell});

  var statsOptionsCell = new Cell();
  statsOptionsCell.setValue({nonQ: ['keysInterval', 'nonQ'], resampleForUI: '1'});
  _.extend(statsOptionsCell, {
    update: function (options) {
      this.modifyValue(_.bind($.extend, $, {}), options);
    },
    equality: _.isEqual
  });

  var samplesRestorerCell = new Cell(function (target, options) {
    return new SamplesRestorer(target.stats.uri, options);
  }).setSources({target: targetCell, options: statsOptionsCell});

  var statsCell = new Cell(function (samplesRestorer) {
    return future.get({
      url: samplesRestorer.url,
      ignoreErrors: true,
      data: samplesRestorer.getRequestData()
    }, samplesRestorer.valueTransformer);
  }).setSources({samplesRestorer: samplesRestorerCell,
                 options: statsOptionsCell,
                 target: targetCell});
  statsCell.keepValueDuringAsync = true;

  statsCell.setRecalculateTime = function () {
    var at = this.context.samplesRestorer.value.nextSampleTime();
    this.recalculateAt(at);
  }

  _.extend(DAO.cells, {
    stats: statsCell,
    statsOptions: statsOptionsCell,
    currentPoolDetails: DAO.cells.currentPoolDetailsCell
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

function renderSmallGraph(jq, stats, statName, isSelected) {
  var data = stats[statName] || [];
  var tstamps = stats.timestamp;
  var plotData = _.map(data, function (e, i) {
    return [tstamps[i], e];
  });

  var lastY = data[data.length-1];

  var maxString = isNaN(lastY) ? '?' : ViewHelpers.formatQuantity(lastY, '', 1000);
  jq.find('.small_graph_label > .value').text(maxString);

  $.plot(jq.find('.small_graph_block'),
         [{color: isSelected ? '#e2f1f9' : '#d95e28',
           data: plotData}],
         {xaxis: {ticks:0, autoscaleMargin: 0.04},
          yaxis: {min:0, ticks:0, autoscaleMargin: 0.04},
          grid: {show:false}});
}

var KnownStats = [
  ["ops", "Operations per second\nSum of set, get, increment, decrement, cas and delete operations per second"],
  ["ep_io_num_read", "Disk fetches\nNumber of disk reads per second"],
  ["mem_used", "Memory bytes used"],
  ["curr_items", "Items count"],
  ["evictions", "RAM ejections per second"],
  ["cmd_set", "Sets per second\nSet operations per second"],
  ["cmd_get", "Gets per second\nGet operations per second"],
  ["bytes_written", "Bytes sent per second\nNetwork bytes sent by all servers, per second"],
  ["bytes_read", "Bytes received per second\nNetwork bytes received by all servers, per second"],
  ["disk_writes", "Persistence write queue size"],
  ["get_hits", "Get hits per second"],
  ["delete_hits", "Delete hits per second"],
  ["incr_hits", "Incr hits per second"],
  ["decr_hits", "Decr hits per second"],
  ["delete_misses", "Delete misses per second"],
  ["decr_misses", "Decr misses per second"],
  ["get_misses", "Get Misses per second"],
  ["incr_misses", "Incr misses per second"],
  ["curr_connections", "Connections count"],
  ["cas_hits", "CAS hits per second"],
  ["cas_badval", "CAS badval per second"],
  ["cas_misses", "CAS misses per second"]
  // ["ep_flusher_todo", "EP-flusher todo"],
  // ["ep_queue_size", "EP queue size"],
  // ["updates", "Updates per second\nSum of set, increment, decrement, cas and delete operations per second"], 
];

var StatGraphs = {
  selected: null,
  recognizedStats: _.pluck(KnownStats, 0),
  visibleStats: [],
  visibleStatsIsDirty: true,
  statNames: {},
  spinners: [],
  preventUpdatesCounter: 0,
  freeze: function () {
    this.preventUpdatesCounter++;
  },
  thaw: function () {
    this.preventUpdatesCounter--;
  },
  freezeIfIE: function () {
    if (!window.G_vmlCanvasManager)
      return _.identity;

    this.freeze();
    return _.bind(this.thaw, this);
  },
  findGraphArea: function (statName) {
    return $('#analytics_graph_' + statName)
  },
  renderNothing: function () {
    var self = this;
    if (self.spinners.length)
      return;

    var main = $('#analytics_main_graph')
    self.spinners.push(overlayWithSpinner(main));
    main.find('.marker').remove();

    _.each(self.visibleStats, function (statName) {
      var area = self.findGraphArea(statName);
      self.spinners.push(overlayWithSpinner(area));
    });

    $('.stats_visible_period').text('?');
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

    _.each(self.spinners, function (s) {
      s.remove();
    });
    self.spinners = [];

    var main = $('#analytics_main_graph')

    if (self.visibleStatsIsDirty) {
      _.each(self.recognizedStats, function (name) {
        var op = _.include(self.visibleStats, name) ? 'show' : 'hide';
        var area = self.findGraphArea(name);
        area[op]();

        var description = self.statNames[name] || name;
        area.find('.small_graph_label .label-text').text(' ' + description)
      });
      self.visibleStatsIsDirty = false;
    }

    var selected = self.selected.value;
    if (stats[selected]) {
      maybeReloadAppDueToLeak();
      plotStatGraph(main, stats, selected, {
        color: '#1d88ad',
        verticalMargin: 1.02
      });
      $('.stats-period-container').toggleClass('missing-samples', !stats[selected].length);
      var visibleSeconds = Math.ceil(stats[selected].length * op.interval / 1000);
      $('.stats_visible_period').text(formatUptime(visibleSeconds));
    }


    _.each(self.visibleStats, function (statName) {
      var ops = stats[statName] || [];
      var area = self.findGraphArea(statName);
      renderSmallGraph(area, stats, statName, selected == statName);
    });
  },
  update: function () {
    this.doUpdate();

    var cell = DAO.cells.stats;
    var stats = cell.value;
    // it is important to calculate refresh time _after_ we render, so
    // that if we're slow we'll safely skip samples
    if (stats && stats.op)
      cell.setRecalculateTime();
  },
  configureStats: function () {
    var self = this;

    var dialog = $('#analytics_settings_dialog');
    var values = {};

    _.each(self.recognizedStats, function (name) {
      values[name] = _.include(self.visibleStats, name);
    });
    setFormValues(dialog, values);

    var observer = dialog.observePotentialChanges(watcher);

    function watcher(e) {
      var checked = $.map(dialog.find('input:checked'), function (el, idx) {
        return el.getAttribute('name');
      }).sort();

      if (_.isEqual(checked, self.visibleStats))
        return;

      self.visibleStats = checked;
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
  init: function () {
    renderTemplate('stats_nav', this.recognizedStats);

    ;(function () {
      var leftCount = (KnownStats.length + 1) >> 1;
      var shuffledPairs = new Array(KnownStats.length);
      var i,k;
      for (i = 0, k = 0; i < KnownStats.length; i += 2, k++) {
        shuffledPairs[i] = KnownStats[k];
        shuffledPairs[i+1] = KnownStats[leftCount + k];
      }
      shuffledPairs.length = KnownStats.length;

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
    })();

    var self = this;

    self.selected = new LinkSwitchCell('graph', {
      bindMethod: 'bind',
      linkSelector: '.analytics-small-graph',
      firstItemIsDefault: true}),

    DAO.cells.stats.subscribeAny($m(this, 'update'));

    var selected = self.selected;

    var t;
    _.each(self.recognizedStats, function (statName) {
      var area = self.findGraphArea(statName);
      if (!area.length) {
        debugger
      }
      area.hide();
      if (!t)
        t = area;
      else
        t = t.add(area);
      selected.addLink(area, statName);
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

    var visibleStatsCookie = $.cookie('vs') || self.recognizedStats.slice(0,4).join(',');
    self.visibleStats = visibleStatsCookie.split(',').sort();

    // init stat names
    $('#analytics_settings_dialog input[type=checkbox]').each(function () {
      var name = this.getAttribute('name');
      var text = $.trim($(this).siblings('.cnt').children('span').text());
      if (text && text.length)
        self.statNames[name] = text;
    });
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
      if (value == '') {
        names.filter('.live_view_of').text('Cluster');
      }
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
