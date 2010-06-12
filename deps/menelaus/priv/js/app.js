//= require <jquery.js>
//= require <jqModal.js>
//= require <jquery.flot.js>
//= require <jquery.ba-bbq.js>
//= require <underscore.js>
//= require <tools.tabs.js>
//= require <jquery.cookie.js>
//= require <misc.js>
//= require <base64.js>
//= require <mkclass.js>
//= require <callbacks.js>
//= require <cells.js>
//= require <hash-fragment-cells.js>
//= require <right-form-observer.js>


// TODO: doesn't work due to apparent bug in jqModal. Consider switching to another modal windows implementation
// $(function () {
//   $(window).keydown(function (ev) {
//     if (ev.keyCode != 0x1b) // escape
//       return;
//     console.log("got escape!");
//     // escape is pressed, now check if any jqModal window is active and hide it
//     _.each(_.values($.jqm.hash), function (modal) {
//       if (!modal.a)
//         return;
//       $(modal.w).jqmHide();
//     });
//   });
// });

function setBoolAttribute(jq, attr, value) {
  if (value) {
    jq.attr(attr, attr);
  } else {
    jq.removeAttr(attr);
  }
}

function normalizeNaN(possNaN) {
	return possNaN << 0;
}

function setFormValues(form, values) {
  form.find('input[type=text], input[type=password], input:not([type])').each(function () {
    var text = $(this);
    var name = text.attr('name');
    var value = String(values[name] || '');
    text.val(value);
  });

  form.find('input[type=checkbox]').each(function () {
    var box = $(this);
    var name = box.attr('name');
    if (!(name in values))
      return;

    var boolValue = values[name];
    if (_.isString(boolValue)) {
      boolValue = (boolValue != "0");
    }

    setBoolAttribute(box, 'checked', boolValue);
  });

  form.find("select").each(function () {
    var select = $(this);
    var name = select.attr('name');
    if (!(name in values))
      return;

    var value = values[name];

    select.find('option').each(function () {
      var option = $(this);
      setBoolAttribute($(this), 'selected', option.val() == value);
    });
  });
}

function handlePasswordMatch(parent) {
  var passwd = parent.find("[name=password]:not([disabled])").val();
  var passwd2 = parent.find("[name=verifyPassword]:not([disabled])").val();
  var show = (passwd != passwd2);
  parent.find('.dont-match')[show ? 'show' : 'hide']();
  parent.find('[type=submit]').each(function () {
    setBoolAttribute($(this), 'disabled', show);
  });
  return !show;
}

function formatUptime(seconds, precision) {
  precision = precision || 8;

  var arr = [[86400, "days", "day"],
             [3600, "hours", "hour"],
             [60, "minutes", "minute"],
             [1, "seconds", "second"]];

  var rv = [];

  $.each(arr, function () {
    var period = this[0];
    var value = (seconds / period) >> 0;
    seconds -= value * period;
    if (value)
      rv.push(String(value) + ' ' + (value > 1 ? this[1] : this[2]));
    return !!--precision;
  });

  return rv.join(', ');
}

;(function () {
  var weekDays = "Sun Mon Tue Wed Thu Fri Sat".split(' ');
  var monthNames = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(' ');
  function _2digits(d) {
    d += 100;
    return String(d).substring(1);
  }

  window.formatAlertTStamp = function formatAlertTStamp(mseconds) {
    var date = new Date(mseconds);
    var rv = [weekDays[date.getDay()],
      ' ',
      monthNames[date.getMonth()],
      ' ',
      date.getDate(),
      ' ',
      _2digits(date.getHours()), ':', _2digits(date.getMinutes()), ':', _2digits(date.getSeconds()),
      ' ',
      date.getFullYear()];

    return rv.join('');
  }

  window.formatLogTStamp = function formatLogTStamp(mseconds) {
    var date = new Date(mseconds);
    var rv = [
      "<strong>",
      _2digits(date.getHours()), ':', _2digits(date.getMinutes()), ':', _2digits(date.getSeconds()),
      "</strong> - ",
      weekDays[date.getDay()],
      ' ',
      monthNames[date.getMonth()],
      ' ',
      date.getDate(),
      ', ',
      date.getFullYear()];

    return rv.join('');
  }
})();

function formatAlertType(type) {
  switch (type) {
  case 'warning':
    return "Warning";
  case 'attention':
    return "Needs Your Attention";
  case 'info':
    return "Informative";
  }
}

function addBasicAuth(xhr, login, password) {
  var auth = 'Basic ' + Base64.encode(login + ':' + password);
  xhr.setRequestHeader('Authorization', auth);
}

function onUnexpectedXHRError(xhr) {
  window.onUnexpectedXHRError = function () {}

  if (Abortarium.isAborted(xhr))
    return;

  // for manual interception
  if ('debuggerHook' in onUnexpectedXHRError) {
    onUnexpectedXHRError['debuggerHook'](xhr);
  }

  var status;
  try {status = xhr.status} catch (e) {};

  if (status == 401) {
    $.cookie('auth', null);
    return reloadApp();
  }

  var reloadInfo = $.cookie('ri');
  var ts;

  var now = (new Date()).valueOf();
  if (reloadInfo) {
    ts = parseInt(reloadInfo);
    if ((now - ts) < 15*1000) {
      $.cookie('ri', null); // clear reload-info cookie, so that
                            // manual reload don't cause 'console has
                            // been reloaded' flash message

      var details = DAO.cells.currentPoolDetailsCell.value;
      var notAlone = details && details.nodes.length > 1;
      var msg = 'The application received multiple invalid responses from the server.  The server log may have details on this error.  Reloading the application has been suppressed.';
      if (notAlone) {
        msg += '\n\nYou may be able to load the console from another server in the cluster.';
      }
      alert(msg);

      return;
    }
  }

  $.cookie('ri', String((new Date()).valueOf()), {expires:0});
  reloadAppWithDelay(500);
}

function postWithValidationErrors(url, data, callback, ajaxOptions) {
  if (!_.isString(data))
    data = serializeForm($(data));
  var finalAjaxOptions = {
    type:'POST',
    url: url,
    data: data,
    success: continuation,
    error: continuation,
    dataType: 'json'
  };
  _.extend(finalAjaxOptions, ajaxOptions || {});
  $.ajax(finalAjaxOptions);
  var action = new ModalAction();
  return

  function continuation(data, textStatus) {
    action.finish();
    if (textStatus != 'success') {
      var status = 0;
      try {
        status = data.status // can raise exception on IE sometimes
      } catch (e) {
        // ignore
      }
      if (status >= 200 && status < 300 && data.responseText == '') {
        return callback.call(this, '', 'success');
      }

      if (status != 400 || textStatus != 'error') {
        return onUnexpectedXHRError(data);
      }

      var errorsData = $.httpData(data, null, this);
      if (!_.isArray(errorsData)) {
        if (errorsData.length == 0)
          errorsData = "unknown reason";
        errorsData = [errorsData];
      }
      callback.call(this, errorsData, 'error');
      return;
    }

    callback.call(this, data, textStatus);
  }
}

var LogoutTimer = {
  reset: function () {
    if (this.timeoutId) {
      clearTimeout(this.timeoutId);
    }
    if (!DAO.login)
      return;
    this.timeoutId = setTimeout($m(this, 'onTimeout'), 300000);
  },
  onTimeout: function () {
    $.cookie('inactivity_reload', '1');
    DAO.setAuthCookie(null);
    reloadApp();
  }
};

$.ajaxSetup({
  error: onUnexpectedXHRError,
  timeout: 5000,
  beforeSend: function (xhr) {
    if (DAO.login) {
      addBasicAuth(xhr, DAO.login, DAO.password);
    }
    xhr.setRequestHeader('invalid-auth-response', 'on');
    xhr.setRequestHeader('Cache-Control', 'no-cache');
    xhr.setRequestHeader('Pragma', 'no-cache');
    LogoutTimer.reset();
  },
  dataFilter: function (data, type) {
    if (type == "json" && data == "")
      throw new Error("empty json");
    return data;
  }
});

var DAO = {
  ready: false,
  version: undefined,
  cells: {},
  onReady: function (thunk) {
    if (DAO.ready)
      thunk.call(null);
    else
      $(window).one('dao:ready', function () {thunk();});
  },
  setAuthCookie: function (user, password) {
    if (user != '') {
      var auth = Base64.encode([user, ':', password].join(''))
      $.cookie('auth', auth);
    } else {
      $.cookie('auth', null);
    }
  },
  loginSuccess: function (data) {
    DAO.ready = true;
    $(window).trigger('dao:ready');
    var rows = data.pools;
    DAO.cells.poolList.setValue(rows);
    DAO.setAuthCookie(DAO.login, DAO.password);

    $('#secure_server_buttons').attr('class', DAO.login ? 'secure_disabled' : 'secure_enabled');

    if (data.implementationVersion) {
      DAO.version = data.implementationVersion;
      DAO.componentsVersion = data.componentsVersion;
      document.title = document.title + " (" + data.implementationVersion + ")"
    }

    DAO.initStatus = data.initStatus || "";
    showInitDialog(DAO.initStatus);
  },
  switchSection: function (section) {
    DAO.cells.mode.setValue(section);
  },
  tryNoAuthLogin: function () {
    $.ajax({
      type: 'GET',
      url: "/pools",
      dataType: 'json',
      async: false,
      success: cb,
      error: cb});

    var rv;
    var auth;

    if (!rv && (auth = $.cookie('auth'))) {
      var arr = Base64.decode(auth).split(':');
      DAO.login = arr[0];
      DAO.password = arr[1];

      $.ajax({
        type: 'GET',
        url: "/pools",
        dataType: 'json',
        async: false,
        success: cb,
        error: cb});
    }

    return rv;

    function cb(data, status) {
      if (status == 'success') {
        DAO.loginSuccess(data);
        rv = true;
      }
    }
  },
  performLogin: function (login, password, callback) {
    this.login = login;
    this.password = password;

    function cb(data, status) {
      if (status == 'success') {
        DAO.loginSuccess(data);
      }
      if (callback)
        callback(status);
    }

    $.ajax({
      type: 'GET',
      url: "/pools",
      dataType: 'json',
      success: cb,
      error: cb});
  },
  getBucketNodesCount: function (_dummy) {
    return DAO.cells.currentPoolDetailsCell.value.nodes.length;
  },
  isInCluster: function () {
    var details = DAO.cells.currentPoolDetails.value
    if (!details)
      return undefined;
    return details.nodes.length > 1;
  }
};

(function () {
  this.mode = new Cell();
  this.poolList = new Cell();

  this.currentPoolDetailsCell = new Cell(function (poolList) {
    function poolDetailsValueTransformer(data) {
      // we clear pool's name to display empty name in analytics
      data.name = '';
      return data;
    }
    var uri = poolList[0].uri;
    return future.get({url: uri}, poolDetailsValueTransformer);
  }).setSources({poolList: this.poolList});

  var statsBucketURL = this.statsBucketURL = new StringHashFragmentCell("statsBucket");

  this.currentStatTargetCell = new Cell(function (poolDetails, mode) {
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
}).call(DAO.cells);

var SamplesRestorer = mkClass({
  initialize: function () {
    this.birthTime = (new Date()).valueOf();
  },
  nextSampleTime: function (ops) {
    var now = (new Date()).valueOf();
    if (!ops)
      return now;
    var samplesInterval = ops['samplesInterval'];
    var at = this.birthTime + Math.ceil((now - this.birthTime)/samplesInterval)*samplesInterval;
    if (at - now < samplesInterval/2)
      at += samplesInterval;
    return at;
  }
});

(function () {
  var targetCell = DAO.cells.currentStatTargetCell;

  var StatsArgsCell = new Cell(function (target) {
    return {url: target.stats.uri};
  }).setSources({target: targetCell});

  var statsOptionsCell = new Cell();
  statsOptionsCell.setValue({nonQ: ['keysInterval', 'nonQ']});
  _.extend(statsOptionsCell, {
    update: function (options) {
      this.modifyValue(_.bind($.extend, $, {}), options);
    },
    equality: _.isEqual
  });

  var samplesRestorerCell = new Cell(function (target, options) {
    return new SamplesRestorer();
  }).setSources({target: targetCell, options: statsOptionsCell});

  var statsCell = new Cell(function (samplesRestorer, options, target) {
    var data = _.extend({}, options);
    _.each(data.nonQ, function (n) {
      delete data[n];
    });

    return future.get({
      url: target.stats.uri,
      data: data
    });
  }).setSources({samplesRestorer: samplesRestorerCell,
                 options: statsOptionsCell,
                 target: targetCell});
  statsCell.keepValueDuringAsync = true;

  statsCell.setRecalculateTime = function () {
    var at = this.context.samplesRestorer.value.nextSampleTime(this.value.op);
    this.recalculateAt(at);
  }

  _.extend(DAO.cells, {
    stats: statsCell,
    statsOptions: statsOptionsCell,
    currentPoolDetails: DAO.cells.currentPoolDetailsCell
  });
})();

var maybeReloadAppDueToLeak = (function () {
  var counter = 300;

  return function () {
    if (!window.G_vmlCanvasManager)
      return;

    if (!--counter)
      reloadPage();
  };
})();

// make sure around 3 digits of value is visible. Less for for too
// small numbers
function truncateTo3Digits(value) {
  var scale = _.detect([100, 10, 1, 0.1], function (v) {return value >= v;}) || 0.01;
  scale = 100 / scale;
  return Math.floor(value*scale)/scale;
}

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

function prepareTemplateForCell(templateName, cell) {
  cell.undefinedSlot.subscribeWithSlave(function () {
    prepareRenderTemplate(templateName);
  });
  if (cell.value === undefined)
    prepareRenderTemplate(templateName);
}

// renderCellTemplate(cell, "something");
// renderCellTemplate(cell, ["something_container", "foorbar"]);
function renderCellTemplate(cell, to, valueTransformer) {
  var template;

  if (_.isArray(to)) {
    template = to[1] + '_template';
    to = to[0];
  } else {
    template = to + "_template";
    to += '_container'
  }

  var toGetter;
  if (_.isString(to)) {
    toGetter = function () {
      return $i(to);
    }
  } else {
    toGetter = function () {
      return to;
    }
  }

  var clearSlave = new Slave(function () {
    prepareAreaUpdate($(toGetter()));
  });
  cell.undefinedSlot.subscribeWithSlave(clearSlave);
  if (cell.value === undefined)
    clearSlave.thunk(cell);

  var renderSlave = new Slave(function (cell) {
    var value = cell.value;
    if (valueTransformer)
      value = valueTransformer(value);
    renderRawTemplate(toGetter(), template, value);
  });
  cell.changedSlot.subscribeWithSlave(renderSlave);
  if (cell.value !== undefined)
    renderSlave.thunk(cell);

  return {
    cancel: function () {
      cell.changedSlot.unsubscribe(renderSlave);
      cell.undefinedSlot.unsubscribe(clearSlave);
    }
  }
}

var OverviewSection = {
  renderStatus: function () {
    var nodes = DAO.cells.currentPoolDetails.value.nodes;
    var buckets = BucketsSection.cells.detailedBuckets.value;

    var totalMem = 0;
    var freeMem = 0;
    _.each(nodes, function (n) {
      totalMem += n.memoryTotal;
      freeMem += n.memoryFree;
    });

    var bucketsSizeTotal = 0;  // The total of the buckets defined
    if(buckets) {
      _.each(buckets, function(b) {
          bucketsSizeTotal += b.basicStats.cacheSize;
      });
    }

    this.clusterMemoryAvailable = totalMem - bucketsSizeTotal*1048576;

    var memoryUtilization = 100-Math.round(freeMem*100/totalMem) << 0;

    var isWarning = memoryUtilization > 90;

    var isCritical = false;
    isCritical = isCritical || _.any(nodes, function (n) {
      return n.status != 'healthy';
    });

    var mcdMemReserved = 0;
    var mcdMemAllocd = 0;
    _.each(nodes, function (n) {
        mcdMemReserved += n.mcdMemoryReserved;
        mcdMemAllocd += n.mcdMemoryAllocated;
      });
    mcdMemReserved *= 1048576;
    var mcdItemUtilization = Math.round(mcdMemReserved*100/totalMem);

    var canJoinCluster = (nodes.length == 1);

    var statusData = {
      isCritical: isCritical,
      isWarning: isWarning,
      canJoinCluster: canJoinCluster,
      nodesCount: nodes.length,
      bucketsCount: buckets && buckets.length,
      bucketsSizeTotal: bucketsSizeTotal,
      memoryUtilization: memoryUtilization,
      memoryFree: freeMem,
      mcdItemUtilization: mcdItemUtilization,
      mcdMemReserved: mcdMemReserved
    };

    renderTemplate('cluster_status', statusData);

    var leaveJoinClass = canJoinCluster ? 'join-possible' : 'leave-possible';
    $('#join_leave_switch').attr('class', leaveJoinClass);
  },
  onFreshNodeList: function () {
    var nodes = DAO.cells.currentPoolDetails.value.nodes;
    renderTemplate('server_list', nodes);
    $('#server_list_container table tr.primary:first-child').addClass('nbrdr');

    this.renderStatus();

    var activeNodeCount = _.select(nodes, function (n) {
      return n.status == 'healthy';
    }).length;

    $('.active_node_count').text(ViewHelpers.count(activeNodeCount, "active node"));
  },
  startJoinCluster: function () {
    var dialog = $('#join_cluster_dialog');
    var form = dialog.find('form');
    $('#join_cluster_dialog_errors_container').empty();
    $('#join_cluster_dialog form').get(0).reset();
    dialog.find("input:not([type]), input[type=text], input[type=password]").not('[name=clusterMemberHostIp], [name=clusterMemberPort]').val('');

    $('#join_cluster_dialog_errors_container').empty();

    showDialog('join_cluster_dialog', {
      onHide: function () {
        form.unbind('submit');
      }});
    form.bind('submit', function (e) {
      e.preventDefault();

      function simpleValidation() {
        var p = {};
        _.each("clusterMemberHostIp clusterMemberPort user password".split(' '), function (name) {
          p[name] = form.find('[name=' + name + ']').val();
        });

        var errors = [];

        if (p['clusterMemberHostIp'] == "")
          errors.push("Web Console IP Address cannot be blank.");
        if (p['clusterMemberPort'] == '')
          errors.push("Web Console Port cannot be blank.");
        if ((p['user'] || p['password']) && !(p['user'] && p['password'])) {
          errors.push("Username and Password must either both be present or missing.");
        }

        return errors;
      }

      var errors = simpleValidation();
      if (errors.length) {
        renderTemplate('join_cluster_dialog_errors', errors);
        return;
      }

      var overlay = overlayWithSpinner(form);

      postWithValidationErrors('/node/controller/doJoinCluster', form, function (data, status) {
        if (status != 'success') {
          overlay.remove();
          renderTemplate('join_cluster_dialog_errors', data)
        } else {
          var user = form.find('[name=user]').val();
          var password = form.find('[name=password]').val();
          DAO.setAuthCookie(user, password);
          $.cookie('cluster_join_flash', '1');
          reloadAppWithDelay(5000);
        }
      }, {
        timeout: 7000
      })
    });
  },
  leaveCluster: function () {
    showDialog("eject_confirmation_dialog", {
      eventBindings: [['.save_button', 'click', function (e) {
        e.preventDefault();
        overlayWithSpinner('#eject_confirmation_dialog');

        var reload = mkReloadWithDelay();
        $.ajax({
          type: 'POST',
          url: DAO.cells.currentPoolDetails.value.controllers.ejectNode.uri,
          data: "otpNode=Self",
          success: reload,
          errors: reload
        });
      }]]
    });
  },
  removeNode: function (otpNode) {
    var details = DAO.cells.currentPoolDetails.value.nodes;
    var node = _.detect(details, function (n) {
      return n.otpNode == otpNode;
    });
    if (!node)
      throw new Error('!node. this is unexpected!');

    showDialog("eject_confirmation_dialog", {
      eventBindings: [['.save_button', 'click', function (e) {
        e.preventDefault();

        overlayWithSpinner('#eject_confirmation_dialog');
        var reload = mkReloadWithDelay();
        $.ajax({
          type: 'POST',
          url: DAO.cells.currentPoolDetails.value.controllers.ejectNode.uri,
          data: {otpNode: node.otpNode},
          error: reload,
          success: reload
        });
      }]]
    });
  },
  init: function () {
    var self = this;
    _.defer(function () {
      BucketsSection.cells.detailedBuckets.subscribe($m(self, 'renderStatus'));
    });
    DAO.cells.currentPoolDetails.subscribe($m(self, 'onFreshNodeList'));
    prepareTemplateForCell('server_list', DAO.cells.currentPoolDetails);
    prepareTemplateForCell('cluster_status', DAO.cells.currentPoolDetails);
    prepareTemplateForCell('pool_list', DAO.cells.poolList);
  },
  onEnter: function () {
    DAO.cells.currentPoolDetailsCell.invalidate();
  }
};

var ServersSection = {
  hostnameComparator: mkComparatorByProp('hostname'),
  pendingEject: [],
  onPoolDetailsReady: function () {
    var self = this;

    $('#servers').toggleClass('rebalancing', false);

    var details = this.poolDetails.value;
    if (!details)
      return;

    var rebalancing = details.rebalanceStatus != 'none';
    $('#servers').toggleClass('rebalancing', rebalancing);

    this.renderNoRebalance(details, rebalancing);
    if (rebalancing)
      return this.renderRebalance(details);
  },
  renderNoRebalance: function (details, rebalancing) {
    var self = this;

    var nodes = details.nodes;
    var nodeNames = _.pluck(nodes, 'hostname');
    var pending = [];
    var active = [];
    _.each(nodes, function (n) {
      if (n.clusterMembership == 'inactiveAdded')
        pending.push(n);
      else
        active.push(n);
    });

    var stillActualEject = [];
    _.each(this.pendingEject, function (node) {
      var original = _.detect(nodes, function (n) {
        return n.otpNode == node.otpNode;
      });
      if (!original || original.clusterMembership == 'inactiveAdded') {
        return;
      }
      stillActualEject.push(original);
      original.pendingEject = true;
    });

    this.pendingEject = stillActualEject;

    pending = pending.concat(this.pendingEject);
    pending.sort(this.hostnameComparator);
    active.sort(this.hostnameComparator);

    this.active = active;
    this.pending = pending;

    this.allNodes = _.uniq(this.active.concat(this.pending));

    _.each(this.allNodes, function (n) {
      n.ejectPossible = !n.pendingEject;
      n.failoverPossible = (n.clusterMembership != 'inactiveFailed');
      n.reAddPossible = (n.clusterMembership == 'inactiveFailed');
    });

    var imbalance = !!pending.length;

    $('#servers').removeClass('imbalance');

    if (!imbalance && !details.balanced) {
      $('#servers').addClass('imbalance');
      imbalance = true;
    }
    
    renderTemplate('active_server_list', active);
    if (!rebalancing)
      renderTemplate('pending_server_list', pending);

    $('#servers .rebalance_button').toggle(imbalance);
    $('#servers .add_button').show();
  },
  renderRebalance: function (details) {
    var progress = this.rebalanceProgress.value;
    if (!progress) {
      progress = {};
    }
    nodes = _.clone(details.nodes);
    nodes.sort(this.hostnameComparator);
    _.each(nodes, function (n) {
      var p = progress[n.otpNode];
      if (!p)
        return;
      n.progress = p.progress;
    });

    renderTemplate('rebalancing_list', nodes);
  },
  onRebalanceProgress: function () {
    var value = this.rebalanceProgress.value;
    console.log("got progress: ", value);
    if (value.status == 'none') {
      this.poolDetails.invalidate();
      return
    }

    this.renderRebalance(this.poolDetails.value);
    this.rebalanceProgress.recalculateAfterDelay(1000);
  },
  init: function () {
    this.poolDetails = DAO.cells.currentPoolDetailsCell;

    this.tabs = new TabsCell("serversTab",
                             "#servers .tabs",
                             "#servers .panes > div",
                             ["active", "pending"]);

    var detailsWidget = this.detailsWidget = new MultiDrawersWidget({
      hashFragmentParam: 'openedServers',
      template: 'server_details',
      elementsKey: 'otpNode',
      drawerCellName: 'detailsCell',
      idPrefix: 'detailsRowID',
      placeholderCSS: '#servers .settings-placeholder',
      placeholderContainerChildCSS: null,
      actionLink: 'openServer',
      actionLinkCallback: function () {
        ThePage.ensureSection('servers');
      },
      uriExtractor: function (nodeInfo) {
        return "/nodes/" + encodeURIComponent(nodeInfo.otpNode);
      },
      valueTransformer: function (nodeInfo, nodeSettings) {
        var rv = _.extend({}, nodeInfo, nodeSettings);
        delete rv.detailsCell;
        return rv;
      }
    });
    this.poolDetails.subscribe(function (cell) {
      detailsWidget.valuesTransformer(cell.value.nodes);
    });

    this.poolDetails.subscribeAny($m(this, "onPoolDetailsReady"));
    prepareTemplateForCell('active_server_list', this.poolDetails);
    prepareTemplateForCell('pending_server_list', this.poolDetails);

    var serversQ = this.serversQ = $('#servers');

    this.poolDetails.subscribeOnUndefined(function () {
      serversQ.find('.rebalance_button, .add_button').hide();
    });

    serversQ.find('.rebalance_button').live('click', $m(this, 'onRebalance'));
    serversQ.find('.add_button').live('click', $m(this, 'onAdd'));
    serversQ.find('.stop_rebalance_button').live('click', $m(this, 'onStopRebalance'));

    this.rebalanceProgress = new Cell(function (poolDetails) {
      if (poolDetails.rebalanceStatus == 'none')
        return;
      return future.get({url: poolDetails.rebalanceProgressUri});
    }, {poolDetails: this.poolDetails});
    this.rebalanceProgress.keepValueDuringAsync = true;
    this.rebalanceProgress.subscribe($m(this, 'onRebalanceProgress'));

    detailsWidget.hookRedrawToCell(this.poolDetails);
  },
  onEnter: function () {
    this.poolDetails.invalidate();
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  },
  onLeave: function () {
    this.detailsWidget.reset();
  },
  onRebalance: function () {
    this.postAndReload(this.poolDetails.value.controllers.rebalance.uri,
                       {knownNodes: _.pluck(this.allNodes, 'otpNode').join(','),
                        ejectedNodes: _.pluck(this.pendingEject, 'otpNode').join(',')});
  },
  onStopRebalance: function () {
    this.postAndReload(this.poolDetails.value.stopRebalanceUri, "");
  },
  onAdd: function () {
    var self = this;
    // cut & pasted from OverviewSection.startJoinCluster 'cause we're
    // reusing it's cluster join dialog for
    // now. OverviewSection.startJoinCluster will probably die soon

    var dialog = $('#join_cluster_dialog');
    var form = dialog.find('form');
    $('#join_cluster_dialog_errors_container').empty();
    $('#join_cluster_dialog form').get(0).reset();
    dialog.find("input:not([type]), input[type=text], input[type=password]").not('[name=clusterMemberHostIp], [name=clusterMemberPort]').val('');

    $('#join_cluster_dialog_errors_container').empty();
    showDialog('join_cluster_dialog', {
      onHide: function () {
        form.unbind('submit');
      }});
    form.bind('submit', function (e) {
      e.preventDefault();

      var data = {}
      _.each("clusterMemberHostIp clusterMemberPort user password".split(' '), function (name) {
        data[name] = form.find('[name=' + name + ']').val();
      });

      function simpleValidation(data) {
        var errors = [];

        if (data['clusterMemberHostIp'] == "")
          errors.push("Web Console IP Address cannot be blank.");
        if (data['clusterMemberPort'] == '')
          errors.push("Web Console Port cannot be blank.");
        if ((data['user'] || data['password']) && !(data['user'] && data['password'])) {
          errors.push("Username and Password must either both be present or missing.");
        }

        return errors;
      }

      var errors = simpleValidation(data);
      if (errors.length) {
        renderTemplate('join_cluster_dialog_errors', errors);
        return;
      }

      $('#join_cluster_dialog_errors_container').html('');
      var overlay = overlayWithSpinner(form);

      var uri = self.poolDetails.value.controllers.addNode.uri;
      self.poolDetails.setValue(undefined);

      var toSend = {
        hostname: data['clusterMemberHostIp'],
        user: data['user'],
        password: data['password']
      };
      if (data['clusterMemberPort'] != '8080')
        toSend['hostname'] += ':' + data['clusterMemberPort']

      postWithValidationErrors(uri, $.param(toSend), function (data, status) {
        self.poolDetails.invalidate();
        overlay.remove();
        if (status != 'success') {
          renderTemplate('join_cluster_dialog_errors', data)
        } else {
          hideDialog('join_cluster_dialog');
        }
      }, {
        timeout: 15000
      })
    });
  },
  findNode: function (hostname) {
    return _.detect(this.allNodes, function (n) {
      return n.hostname == hostname;
    });
  },
  mustFindNode: function (hostname) {
    var rv = this.findNode(hostname);
    if (!rv) {
      throw new Error("failed to find node info for: " + hostname);
    }
    return rv;
  },
  reDraw: function () {
    _.defer($m(this, 'onPoolDetailsReady'));
  },
  ejectNode: function (hostname) {
    var node = this.mustFindNode(hostname);
    if (node.pendingEject)
      return;
    this.pendingEject.push(node);
    this.reDraw();
  },
  failoverNode: function (hostname) {
    var node = this.mustFindNode(hostname);
    this.postAndReload(this.poolDetails.value.controllers.failOver.uri,
                       {otpNode: node.otpNode});
  },
  reAddNode: function (hostname) {
    var node = this.mustFindNode(hostname);
    this.postAndReload(this.poolDetails.value.controllers.reAddNode.uri,
                       {otpNode: node.otpNode});
  },
  removeFromList: function (hostname) {
    var node = this.mustFindNode(hostname);

    if (node.pendingEject) {
      node.pendingEject = false;
      this.pendingEject = _.without(this.pendingEject, node);
      return this.reDraw();
    }

    var ejectNodeURI = this.poolDetails.value.controllers.ejectNode.uri;
    this.postAndReload(ejectNodeURI, {otpNode: node.otpNode});
  },
  postAndReload: function (uri, data) {
    var self = this;
    // keep poolDetails undefined for now
    self.poolDetails.setValue(undefined);
    postWithValidationErrors(uri, $.param(data), function (data, status) {
      // re-calc poolDetails according to it's formula
      self.poolDetails.invalidate();
      if (status == 'error' && data[0].mismatch) {
        self.poolDetails.changedSlot.subscribeOnce(function () {
          var msg = "Somebody else modified cluster configuration.\nRepeat rebalance after checking that changes.";
          alert(msg);
        });
      }
    });
  }
};

var MultiDrawersWidget = mkClass({
  mandatoryOptions: "hashFragmentParam template elementsKey drawerCellName idPrefix".split(" "),
  initialize: function (options) {
    options = this.options = _.extend({
      placeholderCSS: '.settings-placeholder',
      placeholderContainerChildCSS: 'td',
      uriExtractor: function (e) {return e.uri;}
    }, options);

    var missingOptions = _.reject(this.mandatoryOptions, function (n) {
      return (n in options);
    });

    if (missingOptions.length)
      throw new Error("Missing mandatory option(s): " + missingOptions.join(','));

    this.openedNames = new StringSetHashFragmentCell(options.hashFragmentParam);

    if (options.actionLink) {
      configureActionHashParam(options.actionLink, $m(this, 'onActionLinkClick'));
    }

    this.subscriptions = [];
    this.reDrawElements = $m(this, 'reDrawElements');
    this.hookRedrawToCell(this.openedNames);
  },
  hookRedrawToCell: function (cell) {
    cell.subscribe(this.reDrawElements);
  },
  onActionLinkClick: function (uri, isMiddleClick) {
    this.options.actionLinkCallback(uri);
    if (isMiddleClick) {
      this.openElement(uri);
    } else
      this.toggleElement(uri);
  },
  valuesTransformer: function (elements) {
    var self = this;
    var idPrefix = self.options.idPrefix;
    var key = self.options.elementsKey;
    var drawerCellName = self.options.drawerCellName;

    self.elementsByName = {};

    _.each(elements, function (e) {
      e[idPrefix] = _.uniqueId(idPrefix);

      var uriCell = new Cell(function (openedNames) {
        if (this.self.value || !_.include(openedNames, e[key]))
          return this.self.value;

        return self.options.uriExtractor(e);
      }, {openedNames: self.openedNames});
      e[drawerCellName] = new Cell(function (uri) {
        return future.get({url: uri}, function (childItem) {
          if (self.options.valueTransformer)
            childItem = self.options.valueTransformer(e, childItem);
          return childItem;
        });
      }, {uri: uriCell});

      self.elementsByName[e[key]] = e;
    });
    return elements;
  },
  reDrawElements: function () {
    var self = this;

    var subscriptions = self.subscriptions;
    _.each(subscriptions, function (s) {
      s.cancel();
    });
    subscriptions.length = 0;

    $(self.options.placeholderCSS).hide();

    var elementsByName = self.elementsByName;
    if (!elementsByName)
      return;

    _.each(self.openedNames.value, function (name) {
      var element = elementsByName[name];
      if (!element) {
        console.log("element: ", name, "not found");
        return;
      }

      var parentNode = $i(element[self.options.idPrefix]);
      if (!parentNode) {
        console.log("should not happen");
        return;
      }

      var cell = element[self.options.drawerCellName];

      var q = $(parentNode);

      var container;
      var childCSS = self.options.placeholderContainerChildCSS;
      if (childCSS)
        container = q.find(childCSS)[0];
      else
        container = q[0];

      if (!container) {
        throw new Error("MultiDrawersWidget: bad markup!");
      }

      var s = renderCellTemplate(element[self.options.drawerCellName], [container, self.options.template]);
      subscriptions.push(s);

      q.show();
    });
  },
  toggleElement: function (name) {
    if (_.include(this.openedNames.value, name)) {
      this.closeElement(name);
    } else {
      this.openElement(name);
    }
  },
  openElement: function (name) {
    this.openedNames.addValue(name);
  },
  closeElement: function (name) {
    this.openedNames.removeValue(name);
  },
  reset: function () {
    this.openedNames.reset();
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
      }
    });

    var bucketsListTransformer = function (values) {
      self.buckets = values;
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
      // TODO: clear on hide
      this.currentlyShownBucket = bucketDetails;
      renderTemplate('bucket_details_dialog', {b: bucketDetails});
      showDialog('bucket_details_dialog_container');
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
  domId: function (sec) {
    if (sec == 'monitor_buckets')
      return 'buckets';
    return sec;
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
    nav.go('buckets');
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
  startRemovingBucket: function () {
    if (!this.currentlyShownBucket)
      return;

    hideDialog('bucket_details_dialog_container');

    $('#bucket_remove_dialog .bucket_name').text(this.currentlyShownBucket.name);
    showDialog('bucket_remove_dialog');
  },
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

function checkboxValue(value) {
  return value == "1";
}

var AlertsSection = {
  renderAlertsList: function () {
    var value = this.alerts.value;
    renderTemplate('alert_list', _.clone(value.list).reverse());
  },
  changeEmail: function () {
    SettingsSection.gotoSetupAlerts();
  },
  init: function () {
    this.active = new Cell(function (mode) {
      return (mode == "alerts") ? true : undefined;
    }).setSources({mode: DAO.cells.mode});

    this.alerts = new Cell(function (active) {
      var value = this.self.value;
      var params = {url: "/alerts"};
      return future.get(params);
    }).setSources({active: this.active});
    this.alerts.keepValueDuringAsync = true;
    prepareTemplateForCell("alert_list", this.alerts);
    this.alerts.subscribe($m(this, 'renderAlertsList'));
    this.alerts.subscribe(function (cell) {
      // refresh every 30 seconds
      cell.recalculateAt((new Date()).valueOf() + 30000);
    });

    this.alertTab = new TabsCell("alertsTab",
                                 "#alerts .tabs",
                                 "#alerts .panes > div",
                                 ["list", "log"]);

    _.defer(function () {
      SettingsSection.advancedSettings.subscribe($m(AlertsSection, 'updateAlertsDestination'));
    });

    this.logs = new Cell(function (active) {
      return future.get({url: "/logs"}, undefined, this.self.value);
    }).setSources({active: this.active});
    this.logs.subscribe(function (cell) {
      cell.recalculateAt((new Date()).valueOf() + 30000);
    });
    this.logs.subscribe($m(this, 'renderLogsList'));
    prepareTemplateForCell('alert_logs', this.logs);
  },
  renderLogsList: function () {
    renderTemplate('alert_logs', _.clone(this.logs.value.list).reverse());
  },
  updateAlertsDestination: function () {
    var cell = SettingsSection.advancedSettings.value;
    var who = ''
    if (cell && ('email' in cell)) {
      who = cell.email || 'nobody'
    }
    $('#alerts_email_setting').text(who);
  },
  onEnter: function () {
  },
  navClick: function () {
    if (DAO.cells.mode.value == 'alerts') {
      this.alerts.setValue(undefined);
      this.logs.setValue(undefined);
      this.alerts.recalculate();
      this.logs.recalculate();
    }
  }
}

var SettingsSection = {
   processSave: function(self) {
      var dialog = genericDialog({
        header: 'Saving...',
        text: 'Saving settings.  Please wait a bit.',
        buttons: {ok: false, cancel: false}});

      var form = $(self);

      var postData = serializeForm(form);

      form.find('.warn li').remove();

      postWithValidationErrors($(self).attr('action'), postData, function (data, status) {
        if (status != 'success') {
          var ul = form.find('.warn ul');
          _.each(data, function (error) {
            var li = $('<li></li>');
            li.text(error);
            ul.prepend(li);
          });
          $('html, body').animate({scrollTop: ul.offset().top-100}, 250);
          return dialog.close();
        }

        reloadApp(function (reload) {
          if (data && data.newBaseUri) {
            var uri = data.newBaseUri;
            if (uri.charAt(uri.length-1) == '/')
              uri = uri.slice(0, -1);
            uri += document.location.pathname;
          }
          _.delay(_.bind(reload, null, uri), 1000);
        });
      });
  },
  // GET of advanced settings returns structure, while POST accepts
  // only plain key-value set. We convert data we get from GET to
  // format of POST requests.
  flattenAdvancedSettings: function (data) {
    var rv = {};
    $.extend(rv, data.ports); // proxyPort & directPort

    var alerts = data.alerts;
    rv['email'] = alerts['email']
    rv['sender'] = alerts['sender']
    rv['email_alerts'] = alerts['sendAlerts'];

    for (var k in alerts.email_server) {
      rv['email_server_' + k] = alerts.email_server[k];
    }

    for (var k in alerts.alerts) {
      rv['alert_' + k] = alerts.alerts[k];
    }

    return rv;
  },
  handleHideShowCheckboxes: function () {
    var alertSet = $('#alert_set');
    var method = (alertSet.get(0).checked) ? 'addClass' : 'removeClass'
    $('#alerts_settings_guts')[method]('block');

    var secureServ = $('#secure_serv');
    var isVisible = (secureServ.get(0).checked);
    method = isVisible ? 'addClass' : 'removeClass';
    $('#server_secure')[method]('block');
    setBoolAttribute($('#server_secure input:not([type=hidden])'), 'disabled', !isVisible)
  },
  init: function () {
    var self = this;

    $('#alert_set, #secure_serv').click($m(self, 'handleHideShowCheckboxes'));

    self.tabs = new TabsCell("settingsTab",
                             '#settings .tabs',
                             '#settings .panes > div',
                             ['basic', 'advanced']);
    self.webSettings = new Cell(function (mode) {
      if (mode != 'settings')
        return;
      return future.get({url: '/settings/web'});
    }).setSources({mode: DAO.cells.mode});

    self.advancedSettings = new Cell(function (mode) {
      // alerts section depend on this too
      if (mode != 'settings' && mode != 'alerts')
        return;
      return future.get({url: '/settings/advanced'}, $m(self, 'flattenAdvancedSettings'));
    }).setSources({mode: DAO.cells.mode});

    self.webSettingsOverlay = null;
    self.advancedSettingsOverlay = null;

    function bindOverlay(cell, varName, form) {
      function onUndef() {
        self[varName] = overlayWithSpinner(form);
      }
      function onDef() {
        var spinner = self[varName];
        if (spinner) {
          self[varName] = null;
          spinner.remove();
        }
      }
      cell.subscribe(onUndef, {'undefined': true, 'changed': false});
      cell.subscribe(onDef, {'undefined': false, 'changed': true});
    }

    bindOverlay(self.webSettings, 'webSettingsOverlay', '#basic_settings_form');
    bindOverlay(self.advancedSettings, 'advancedSettingsOverlay', '#advanced_settings_form');

    self.webSettings.subscribe($m(this, 'fillBasicForm'));
    self.advancedSettings.subscribe($m(this, 'fillAdvancedForm'));

    var basicSettingsForm = $('#basic_settings_form');
    basicSettingsForm.observePotentialChanges(function () {
      if (basicSettingsForm.find('#secure_serv').is(':checked')) {
        handlePasswordMatch(basicSettingsForm);
      } else {
        setBoolAttribute(basicSettingsForm.find('[type=submit]'), 'disabled', false)
      }
    });

    $('#settings form').submit(function (e) {
      e.preventDefault();
      SetingsSection.processSave(this);
    });
  },
  gotoSetupAlerts: function () {
    var self = this;

    self.tabs.setValue('advanced');

    function switchAlertsOn() {
      if (self.advancedSettings.value && ('email_alerts' in self.advancedSettings.value)) {
        _.defer(function () { // make sure we do it after form is filled
          setBoolAttribute($('#advanced_settings_form [name=email_alerts]'), 'checked', true);
          self.handleHideShowCheckboxes();
        });
        return
      }

      self.advancedSettings.changedSlot.subscribeOnce(switchAlertsOn);
    }

    switchAlertsOn();
    nav.go('settings');
  },
  gotoSecureServer: function () {
    var self = this;

    self.tabs.setValue('basic');
    nav.go('settings');

    function switchSecureOn() {
      if (self.webSettings.value && ('port' in self.webSettings.value)) {
        _.defer(function () {
          setBoolAttribute($('#secure_serv'), 'checked', true);
          self.handleHideShowCheckboxes();
          $('#basic_settings_form input[name=username]').get(0).focus();
        });
        return;
      }

      self.webSettings.changedSlot.subscribeOnce(switchSecureOn);
    }
    switchSecureOn();
  },
  fillBasicForm: function () {
    var form = $('#basic_settings_form');
    setFormValues(form, this.webSettings.value);
    form.find('[name=verifyPassword]').val(this.webSettings.value['password']);
    setBoolAttribute($('#secure_serv'), 'checked', !!(this.webSettings.value['username']));
    this.handleHideShowCheckboxes();
  },
  fillAdvancedForm: function () {
    setFormValues($('#advanced_settings_form'), this.advancedSettings.value);
    this.handleHideShowCheckboxes();
  },
  onEnter: function () {
    // this.advancedSettings.setValue({});
    // this.advancedSettings.recalculate();

    // this.webSettings.setValue({});
    // this.webSettings.recalculate();
  },
  onLeave: function () {
    $('#settings form').each(function () {
      this.reset();
    });
  }
};

// TODO: move this to other places & kill this due to latest screens
// not having that section
var NodeSettingsSection = {
  showNodeSettings: function (otpNode) {
    throw new Error("should not happen");
    // nav.go('nodeSettings');
    // NodeSettingsSection.cells.nodeName.setValue(otpNode);
  },
  init: function () {
  },
  onEdit: function () {
    NodeDialog.startPage_resources('Self', 'edit_resources', {regularDialog: true});
  },

  startLicenseDialog: function (node) {
    NodeDialog.startPage_license(node, 'edit_server_license', {
      submitSelector: 'button.save_button',
      successFunc: function(node, pagePrefix) {
        $('#edit_server_license_dialog').jqmHide();
        NodeDialog.startPage_resources(node, 'edit_resources', {regularDialog: true});
      }
    });
    showDialog('edit_server_license_dialog');
  },

  // The regularDialog boolean flag allows for code-reuse and is false
  // when we're in the initial-config-wizard context.
  //
  startMemoryDialog: function (node, regularDialog) {
    var parentName = '#edit_server_memory_dialog';

    $(parentName + ' .quota_error_message').hide();

    $.ajax({
      type:'GET', url:'/nodes/' + node, dataType: 'json', async: false,
      success: cb, error: cb});

    function cb(data, status) {
      if (status == 'success') {
        var m = data['memoryQuota'];
        if (m == null || m == "none") {
          m = "";
        }

        $(parentName).find('[name=quota]').val(m);
      }
    }

    $(parentName + ' button.save_button').click(function (e) {
        e.preventDefault();

        $(parentName + ' .quota_error_message').hide();

        var m = $(parentName).find('[name=quota]').val() || "";
        if (m == "") {
          m = "none";
        }

        $.ajax({
          type:'POST', url:'/nodes/' + node + '/controller/settings',
          data: 'memoryQuota=' + m,
          async:false, success:cbPost, error:cbPost
        });

        function cbPost(data, status) {
          if (status == 'success') {
            $(parentName).jqmHide();

            if (regularDialog == false) {
              showInitDialog("resources"); // Same screen used in init-config wizard.
            } else {
              OverviewSection.showNodeSettings(node);
            }
          } else {
            $(parentName + ' .quota_error_message').show();
          }
        }
      });

    showDialog('edit_server_memory_dialog');
  },

  startAddLocationDialog : function (node, storageKind, regularDialog) {
    var parentName = '#add_storage_location_dialog';

    $(parentName + ' .storage_location_error_message').hide();

    $(parentName).find('input[type=text]').val();

    $(parentName + ' button.save_button').click(function (e) {
        e.preventDefault();

        $(parentName + ' .storage_location_error_message').hide();

        var p = $(parentName).find('[name=path]').val() || "";
        var q = $(parentName).find('[name=quota]').val() || "";
        if (q == "") {
          q = "none";
        }

        $.ajax({
          type:'POST', url:'/nodes/' + node + '/controller/resources',
          data: 'path=' + p + '&quota=' + q + '&kind=' + storageKind,
          async:false, success:cbPost, error:cbPost
        });

        function cbPost(data, status) {
          if (status == 'success') {
            $(parentName).jqmHide();

            if (regularDialog == false) {
              showInitDialog("resources"); // Same screen used in init-config wizard.
            } else {
              OverviewSection.showNodeSettings(node);
            }
          } else {
            $(parentName + ' .storage_location_error_message').show();
          }
        }
      });

    $(parentName + ' .add_storage_location_title').text("Add " + storageKind.toUpperCase() + " Storage Location");

    showDialog('add_storage_location_dialog');
  },

  startRemoveLocationDialog : function (node, path, regularDialog) {
    if (confirm("Are you sure you want to remove the storage location: " + path + "?  " +
                "Click OK to Remove.")) {
      $.ajax({
        type:'DELETE',
        url:'/nodes/' + node + '/resources/' + encodeURIComponent(path),
        async:false
      });

      if (regularDialog == false) {
        showInitDialog("resources"); // Same screen used in init-config wizard.
      } else {
        OverviewSection.showNodeSettings(node);
      }
    }
  }
};

var DummySection = {
  onEnter: function () {}
};

var BreadCrumbs = {
  update: function () {
    var sec = DAO.cells.mode.value;
    var path = [];

    function pushSection(name) {
      var el = $('#switch_' + name);
      path.push([el.text(), el.attr('href')]);
    }

    var container = $('.bread_crumbs > ul');
    container.html('');

    $('.currentNav').removeClass('currentNav');
    $('#switch_' + sec).addClass('currentNav');

    // TODO: Revisit bread-crumbs for server-specific or bucket-specific drill-down screens.
    //
    return;

    if (sec == 'analytics' && DAO.cells.statsBucketURL.value) {
      pushSection('buckets')
      var bucketInfo = DAO.cells.currentStatTargetCell.value;
      if (bucketInfo) {
        path.push([bucketInfo.name, '#visitBucket='+bucketInfo.uri]);
      }
    } else
      pushSection(sec);

    _.each(path.reverse(), function (pair) {
      var name = pair[0];
      var href = pair[1];

      var li = $('<li></li>');
      var a = $('<a></a>');
      a.attr('href', href);
      a.text(name);

      li.prepend(a);

      container.prepend(li);
    });

    container.find(':first-child').addClass('nobg');
  },
  init: function () {
    var cells = DAO.cells;
    var update = $m(this, 'update');

    cells.mode.subscribe(update);
    cells.statsBucketURL.subscribe(update);
    cells.currentStatTargetCell.subscribe(update);
  }
};

var ThePage = {
  sections: {overview: OverviewSection,
             servers: ServersSection,
             analytics: AnalyticsSection,
             buckets: BucketsSection,
             alerts: AlertsSection,
             settings: SettingsSection,
             nodeSettings: NodeSettingsSection,
             monitor_buckets: BucketsSection,
             monitor_servers: OverviewSection},

  coming: {monitor_buckets:true, monitor_servers:true, settings:true},

  currentSection: null,
  currentSectionName: null,
  signOut: function () {
    $.cookie('auth', null);
    reloadApp();
  },
  ensureSection: function (section) {
    if (this.currentSectionName != section)
      this.gotoSection(section);
  },
  gotoSection: function (section) {
    if (!(this.sections[section])) {
      throw new Error('unknown section:' + section);
    }
    if (this.currentSectionName == section) {
      if ('navClick' in this.currentSection)
        this.currentSection.navClick();
      else
        this.currentSection.onEnter();
    } else
      setHashFragmentParam('sec', section);
  },
  initialize: function () {
    _.each(_.uniq(_.values(this.sections)), function (sec) {
      if (sec.init)
        sec.init();
    });
    BreadCrumbs.init();

    DAO.onReady(function () {
      if (DAO.login) {
        $('.sign-out-link').show();
      }
    });

    var self = this;
    watchHashParamChange('sec', 'overview', function (sec) {
      var oldSection = self.currentSection;
      var currentSection = self.sections[sec];
      if (!currentSection) {
        self.gotoSection('overview');
        return;
      }
      self.currentSectionName = sec;
      self.currentSection = currentSection;

      DAO.switchSection(sec);

      var secId = sec;
      if (currentSection.domId != null) {
        secId = currentSection.domId(sec);
      }

      if (self.coming[sec] == true && window.location.href.indexOf("FORCE") < 0) {
        secId = 'coming';
      }

      $('#mainPanel > div:not(.notice)').css('display', 'none');
      $('#'+secId).css('display','block');

      // Allow reuse of same section DOM for different contexts, via CSS.
      // For example, secId might be 'buckets' and sec might by 'monitor_buckets'.
      $('#'+secId)[0].className = sec;

      _.defer(function () {
        if (oldSection && oldSection.onLeave)
          oldSection.onLeave();
        self.currentSection.onEnter();
        $(window).trigger('sec:' + sec);
      });
    });
  }
};

_.extend(ViewHelpers, {
  thisElement: function (body) {
    var id = _.uniqueId("thisElement");

    AfterTemplateHooks.push(function () {
      var marker = $($i(id));
      var element = marker.parent();
      marker.remove();

      body.call(element.get(0), element);
    });

    return ["<span id='", id, "'></span>"].join('');
  },

  setPercentBar: function (percents) {
    return this.thisElement(function (q) {
      percents = (percents << 0); // coerces NaN and infinities to 0
      q.find('.used').css('width', String(percents)+'%')
    });
  },
  setAttribute: function (name, value) {
    return this.thisElement(function (q) {
      q.attr(name, value);
    });
  },
  count: function (count, text) {
    if (count == null)
      return '?' + text + '(s)';
    count = Number(count);
    if (count > 1) {
      text += 's';
    }
    return [String(count), ' ', text].join('')
  },
  renderHealthClass: function (status) {
    if (status == "healthy")
      return "up";
    else
      return "down";
  },
  formatLogTStamp: function (ts) {
    return window.formatLogTStamp(ts);
  },
  formatQuantity: function (value, kind, K) {
    if (kind == null)
      kind = 'B'; //bytes is default

    K = K || 1024;
    var M = K*K;
    var G = M*K;
    var T = G*K;

    var t = _.detect([[T,'T'],[G,'G'],[M,'M'],[K,'K']], function (t) {return value > 1.1*t[0]});
    t = t || [1, ''];
    return [truncateTo3Digits(value/t[0]), t[1], kind].join('');
  },

  renderPendingStatus: function (node) {
    if (node.clusterMembership == 'inactiveFailed') {
      if (node.pendingEject) {
        return "PENDING EJECT FAILED OVER"
      } else {
        return "FAILED OVER";
      }
    }
    if (node.pendingEject) {
      return "PENDING EJECT";
    }
    if (node.clusterMembership == 'active')
      return '';
    if (node.clusterMembership == 'inactiveAdded') {
      return 'PENDING ADD';
    }
    debugger
    throw new Error('cannot reach');
  }
});

function hideAuthForm() {
  $(document.body).removeClass('auth');
}

function loginFormSubmit() {
  var login = $('#login_form [name=login]').val();
  var password = $('#login_form [name=password]').val();
  var spinner = overlayWithSpinner('#login_form', false);
  $('#login_form').addClass('noform');
  DAO.performLogin(login, password, function (status) {
    spinner.remove();
    $('#login_form').removeClass('noform');

    if (status == 'success') {
      hideAuthForm();
      return;
    }

    $('#auth_failed_message').show();
  });
  return false;
}

window.nav = {
  go: $m(ThePage, 'gotoSection')
};

$(function () {
  $(document.body).removeClass('nojs');
  $(document.body).addClass('auth');

  _.defer(function () {
    var e = $('#auth_dialog [name=login]').get(0);
    try {e.focus();} catch (ex) {}
  });

  if ($.cookie('inactivity_reload')) {
    $.cookie('inactivity_reload');
    $('#auth_inactivity_message').show();
  }

  if ($.cookie('cluster_join_flash')) {
    $.cookie('cluster_join_flash', null);
    displayNotice('You have successfully joined the cluster');
  }
  if ($.cookie('ri')) {
    var reloadInfo = $.cookie('ri');
    var ts;

    var now = (new Date()).valueOf();
    if (reloadInfo) {
      ts = parseInt(reloadInfo);
      if ((now - ts) > 2*1000) {
        $.cookie('ri', null);
      }
    }
    displayNotice('An error was encountered when requesting data from the server.  ' +
		  'The console has been reloaded to attempt to recover.  There ' +
		  'may be additional information about the error in the log.');
  }

  ThePage.initialize();

  DAO.onReady(function () {
    $(window).trigger('hashchange');
  });

  $('#server_list_container .expander, #server_list_container .name').live('click', function (e) {
    var container = $('#server_list_container');
    var mydetails = $(e.target).parents("#server_list_container .primary").next();
    var opened = mydetails.hasClass('opened');

    mydetails.toggleClass('opened', !opened);
    mydetails.prev().find(".expander").toggleClass('expanded', !opened);
  });

  var spinner = overlayWithSpinner('#login_form', false);
  try {
    if (DAO.tryNoAuthLogin()) {
      hideAuthForm();
    }
  } finally {
    try {
      spinner.remove();
    } catch (__ignore) {}
  }
});

$(window).bind('template:rendered', function () {
  $('table.lined_tab tr:has(td):odd').addClass('highlight');
});

$('.remove_bucket').live('click', function() {
  BucketsSection.startRemovingBucket();
});

$(function () {
  var cookie = _.bind($.cookie, $, '_gs');
  (function (expander) {
    function on() {
      expander.addClass('expanded');
      $('#get_started').addClass('block');
      cookie('1', {expires: 65535});
    }
    function off() {
      expander.removeClass('expanded');
      $('#get_started').removeClass('block');
      cookie('0', {expires: 65535});
    }
    expander.click(function() {
      var op = expander.hasClass('expanded') ? off : on;
      op();
    });
    if (cookie() == '0') {
      off();
    } else {
      on();
    }
  })($('#get_started_expander'));
});

function genericDialog(options) {
  options = _.extend({buttons: {ok: true,
                                cancel: true},
                      modal: true,
                      callback: function () {
                        instance.close();
                      }},
                     options);
  var text = options.text || 'I forgot to put text';
  var header = options.header || 'I forgot to put header';
  var dialogTemplate = $('#generic_dialog');
  var dialog = $('<div></div>');
  dialog.attr('class', dialogTemplate.attr('class'));
  dialog.attr('id', _.uniqueId('generic_dialog_'));
  dialogTemplate.after(dialog);
  dialog.html(dialogTemplate.html());

  dialogTemplate = null;

  function brIfy(text) {
    return _.map(text.split("\n"), escapeHTML).join("<br>");
  }

  dialog.find('.lbox_header').html(options.headerHTML || brIfy(header));
  dialog.find('.dialog-text').html(options.textHTML || brIfy(text));

  var b = options.buttons;
  if (!b.ok && !b.cancel) {
    dialog.find('.save_cancel').hide();
  } else {
    dialog.find('.save_cancel').show();
    var ok = b.ok;
    var cancel = b.cancel;

    if (ok === true)
      ok = 'OK';
    if (cancel === true)
      cancel == 'CANCEL';

    function bind(jq, on, name) {
      jq[on ? 'show' : 'hide']();
      if (on) {
        jq.bind('click', function (e) {
          e.preventDefault();
          options.callback.call(this, e, name, instance);
        });
      }
    }
    bind(dialog.find(".save_button"), ok, 'ok');
    bind(dialog.find('.cancel_button'), cancel, 'cancel');
  }

  var modal = options.modal ? new ModalAction() : null;

  showDialog(dialog, {
    onHide: function () {
      _.defer(function () {
        dialog.remove();
      });
    }
  });

  var instance = {
    dialog: dialog,
    close: function () {
      if (modal)
        modal.finish();
      hideDialog(dialog);
    }
  };

  return instance;
}

function showAbout() {
  function updateVersion() {
    var components = DAO.componentsVersion;
    if (components)
      $('#about_versions').text("Version: " + components['ns_server']);
    else {
      $.get('/versions', function (data) {
        DAO.componentsVersion = data.componentsVersion;
        updateVersion();
      }, 'json')
    }
  }
  updateVersion();
  showDialog('about_server_dialog');
}

function showInitDialog(page, opt) {
  opt = opt || {};

  var pages = [ "welcome", "resources", "cluster", "secure" ];

  if (page == "")
    page = "welcome";

  if (DAO.initStatus == "done") // If our current initStatus is already "done",
    page = "done";              // then don't let user go back through init dialog.

  for (var i = 0; i < pages.length; i++) {
    if (page == pages[i]) {
      if (NodeDialog["startPage_" + page]) {
        NodeDialog["startPage_" + page]('Self', 'init_' + page, opt);
      }
      $(document.body).addClass('init_' + page);
    }
  }

  for (var i = 0; i < pages.length; i++) { // Hide in a 2nd loop for more UI stability.
    if (page != pages[i]) {
      $(document.body).removeClass('init_' + pages[i]);
    }
  }

  if (DAO.initStatus != page) {
    DAO.initStatus = page;
    $.ajax({
      type:'POST', url:'/node/controller/initStatus', data: 'value=' + page
    });
  }
}

var NodeDialog = {
  // The pagePrefix looks like 'init_license', and allows reusability.
  startPage_license: function(node, pagePrefix, opt) {
    var parentName = '#' + pagePrefix + '_dialog';

    opt = opt || {};

    $(parentName + ' .license_failed_message').hide();

    $.ajax({
      type:'GET', url:'/nodes/' + node, dataType: 'json', async: false,
      success: cb, error: cb});

    function cb(data, status) {
      if (status == 'success') {
        var lic = data.license;
        if (lic == null || lic == "") {
          lic = "2372AA-F32F1G-M3SA01"; // Hardcoded BETA license.
        }

        $(parentName).find('[name=license]').val(lic);
      }
    }

    var submitSelector = opt['submitSelector'] || 'input.next';

    $(parentName + ' ' + submitSelector).click(function (e) {
        e.preventDefault();

        $(parentName + ' .license_failed_message').hide();

        var license = $(parentName).find('[name=license]').val() || "";

        $.ajax({
          type:'POST', url:'/nodes/' + node + '/controller/settings',
          data: 'license=' + license,
          async:false, success:cbPost, error:cbPost
        });

        function cbPost(data, status) {
          if (status == 'success') {
            if (opt['successFunc'] != null) {
              opt['successFunc'](node, pagePrefix);
            } else {
              showInitDialog(opt["successNext"] || "resources");
            }
          } else {
            $(parentName + ' .license_failed_message').show();
          }
        }
      });
  },
  startPage_resources: function(node, pagePrefix, opt) {
    var parentName = '#' + pagePrefix + '_dialog';

    opt = opt || {};

    $.ajax({
      type:'GET', url:'/nodes/' + node, dataType: 'json', async: false,
      success: cb, error: cb});

    function cb(data, status) {
      data['node'] = data['node'] || node;

      if (status == 'success') {
        data['regularDialog'] = opt['regularDialog'] || false; // Need explicit false instead of undefined.

        if (pagePrefix == 'edit_resources') {
          renderTemplate('node_properties', data);
        }

        var c = $(parentName + ' .resource_panel_container')[0];
        renderTemplate('resource_panel', data, c);
      }
    }
  },
  startPage_secure: function(node, pagePrefix, opt) {
    var parentName = '#' + pagePrefix + '_dialog';

    $(parentName + ' form').submit(function (e) {
      e.preventDefault();

      var pw = $(parentName).find('[name=password]').val();
      if (pw == null || pw == "") {
        showInitDialog("done");
        return;
      }

      SettingsSection.processSave(this);
    });
  }
};

NodeDialog.startPage_welcome = NodeDialog.startPage_license;

var originalOnError;
(function () {
  var sentReports = 0;
  var ErrorReportsLimit = 8;
  originalOnError = window.onerror;

  function appOnError(message, fileName, lineNo) {
    var report = [];
    if (++sentReports < ErrorReportsLimit) {
      report.push("Got unhandled error: ", message, "\nAt: ", fileName, ":", lineNo, "\n");
      var bt = collectBacktraceViaCaller();
      if (bt) {
        report.push("Backtrace:\n", bt);
      }
      if (sentReports == ErrorReportsLimit - 1) {
        report.push("Further reports will be suppressed\n")
      }
    }

    // mozilla can report errors in some cases when user leaves current page
    // so delay report sending
    _.delay(function () {
      function ignore() {}
      $.ajax({type: 'POST',
              url: "/logClientError",
              data: report.join(''),
              success: ignore,
              error: ignore});
    }, 500);

    if (originalOnError)
      originalOnError.call(window, message, fileName, lineNo);
  }
  window.onerror = appOnError;
})();

function displayNotice(text) {
  var div = $('<div></div>');
  var tname = 'notice';
  if (text.indexOf('error') >= 0) {
    tname = 'noticeErr';
  }
  renderTemplate(tname, {text: text}, div.get(0));
  $('#notice_container').prepend(div.children());
}

$('.notice').live('click', function () {
  $(this).fadeOut('fast');
});

$('.tooltip').live('click', function (e) {
  e.preventDefault();

  var jq = $(this);
  if (jq.hasClass('active_tooltip')) {
    return;
  }

  jq.addClass('active_tooltip');
  var msg = jq.find('.tooltip_msg')
  msg.hide().fadeIn('slow', function () {this.removeAttribute('style')});

  function resetEffects() {
    msg.stop();
    msg.removeAttr('style');
    if (timeout) {
      clearTimeout(timeout);
      timeout = undefined;
    }
  }

  function hide() {
    resetEffects();

    jq.removeClass('active_tooltip');
    jq.unbind();
  }

  var timeout;

  jq.bind('click', function (e) {
    e.stopPropagation();
    hide();
  })
  jq.bind('mouseout', function (e) {
    timeout = setTimeout(function () {
      msg.fadeOut('slow', function () {
        hide();
      });
    }, 250);
  })
  jq.bind('mouseover', function (e) {
    resetEffects();
  })
});

$(function () {
  var re = /javascript:nav.go\(['"](.*?)['"]\)/
  $("a[href^='javascript:nav.go(']").each(function () {
    var jq = $(this);
    var href = jq.attr('href');
    var match = re.exec(href);
    var section = match[1];
    jq.attr('href', '#sec=' + section);
  });
});

// clicks to links with href of '#<param>=' will be
// intercepted. Default action (navigating) will be prevented and body
// will be executed.
//
// Middle-clicks that open link in new tab/window will not be (and
// cannot be) intercepted
//
// We use this function to preserve other state that may be in url
// hash string in normal case, while still supporting middle-clicking.
function watchHashParamLinks(param, body) {
  param = '#' + param + '=';
  $('a').live('click', function (e) {
    var href = $(this).attr('href');
    if (href == null || href.slice(0,param.length) != param)
      return;
    e.preventDefault();
    body.call(this, e, href.slice(param.length));
  });
}
watchHashParamLinks('sec', function (e, href) {
  nav.go(href);
});

// used for links that do some action (like displaying certain bucket,
// dialog, ...). This function adds support for middle clicking on
// such action links.
function configureActionHashParam(param, body) {
  // this handles normal clicks (NOTE: no change to url/history is
  // done in that case)
  watchHashParamLinks(param, function (e, hash) {
    body(hash);
  });
  // this handles middle clicks. In such case the only hash fragment
  // of our url will be 'param'. We delete that param and call body
  DAO.onReady(function () {
    var value = getHashFragmentParam(param);
    if (value) {
      setHashFragmentParam(param, null);
      body(value, true);
    }
  });
}
