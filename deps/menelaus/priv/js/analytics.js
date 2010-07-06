var maybeReloadAppDueToLeak = (function () {
  var counter = 300;

  return function () {
    if (!window.G_vmlCanvasManager)
      return;

    if (!--counter)
      reloadPage();
  };
})();

function renderLargeGraph(main, data) {
  maybeReloadAppDueToLeak();

  var minX, minY = 1/0;
  var maxX, maxY = -1/0;
  var minInf = minY;
  var maxInf = maxY;

  var plotData = _.map(data, function (e, i) {
    var x = -data.length + i+1
    if (e <= minY) {
      minX = x;
      minY = e;
    }
    if (e >= maxY) {
      maxX = x;
      maxY = e;
    }
    return [x, e];
  });

  $.plot(main,
         [{color: '#1d88ad',
           data: plotData}],
         {xaxis: {ticks:0, autoscaleMargin: 0.04},
          yaxis: {tickFormatter: function (val, axis) {return ViewHelpers.formatQuantity(val, '', 1000);}},
          grid: {borderWidth: 0},
          hooks: {draw: [drawMarkers]}});

  function singleMarker(center, value) {
    var text;
    value = ViewHelpers.formatQuantity(value, '', 1000);

    text = String(value);
    var marker = $('<span class="marker"><span class="l"></span><span class="r"></span></span>');
    marker.find('.l').text(text);
    main.append(marker);
    marker.css({
      position: 'absolute',
      top: center.top - 16 + 'px',
      left: center.left - 10 + 'px'
    });
    return marker;
  }

  function drawMarkers(plot) {
    main.find('.marker').remove();

    if (minY != minInf && minY != 0) {
      var offset = plot.pointOffset({x: minX, y: minY});
      singleMarker(offset, minY).addClass('marker-min');
    }

    if (maxY != maxInf) {
      var offset = plot.pointOffset({x: maxX, y: maxY});
      singleMarker(offset, maxY).addClass('marker-max');
    }
  }
}

function renderSmallGraph(jq, data, isSelected) {
  var average = _.foldl(data, 0, function (s,v) {return s+v}) / data.length;
  var avgString = ViewHelpers.formatQuantity(average, '', 1000);
  jq.find('.small_graph_label > .value').text(avgString);

  var plotData = _.map(data, function (e, i) {
    return [i+1, e];
  });

  $.plot(jq.find('.small_graph_block'),
         [{color: isSelected ? '#e2f1f9' : '#d95e28',
           data: plotData}],
         {xaxis: {ticks:0, autoscaleMargin: 0.04},
          yaxis: {ticks:0, autoscaleMargin: 0.04},
          grid: {show:false}});
}

var StatGraphs = {
  selected: null,
  recognizedStats: ("ops hit_ratio updates misses total_items curr_items bytes_read cas_misses "
                    + "delete_hits conn_yields get_hits delete_misses total_connections "
                    + "curr_connections threads bytes_written incr_hits get_misses "
                    + "listen_disabled_num decr_hits cmd_flush engine_maxbytes bytes incr_misses "
                    + "cmd_set decr_misses accepting_conns cas_hits limit_maxbytes cmd_get "
                    + "connection_structures cas_badval auth_cmds evictions").split(' '),
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
    stats = stats.op;
    if (!stats)
      return self.renderNothing();

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
      renderLargeGraph(main, stats[selected]);
      $('.stats_visible_period').text(Math.ceil(stats[selected].length * stats['samplesInterval'] / 1000));
    }


    _.each(self.visibleStats, function (statName) {
      var ops = stats[statName] || [];
      var area = self.findGraphArea(statName);
      renderSmallGraph(area, ops, selected == statName);
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

    var visibleStatsCookie = $.cookie('vs') || 'ops,misses,cmd_get,cmd_set';
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
    DAO.cells.stats.subscribe($m(this, 'onKeyStats'));
    prepareTemplateForCell('top_keys', DAO.cells.currentStatTargetCell);

    DAO.cells.statsOptions.update({
      "stat": "combined",
      "keysOpsPerSecondZoom": 'now',
      "keysInterval": 5000
    });

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
