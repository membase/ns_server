//= require <jquery.js>
//= require <jqModal.js>
// !not used!= require <raphael.js>
// !not used!= require <g.raphael.js>
// !not used!= require <g.line.js>
//= require <jquery.flot.js>
//= require <jquery.ba-bbq.js>
// !not used!= require <jquery.jeditable.js>
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

  var reloadInfo = $.cookie('ri');
  var ts;

  var now = (new Date()).valueOf();
  if (reloadInfo) {
    ts = parseInt(reloadInfo);
    if ((now - ts) < 15*1000) {
      alert('A second server failure has been detected in a short period of time.  The error has been logged.  Reloading the application has been suppressed.\n\nYou should consider browsing to another server in the cluster.');
      return;
    }
  }

  alert("Either a network or server side error has occured.  The server has logged the error.  We will reload the console now to attempt to recover.");
  $.cookie('ri', String((new Date()).valueOf()), {expires:0});
  reloadApp();
}

function postWithValidationErrors(url, data, callback) {
  if (!_.isString(data))
    data = $(data).serialize();
  $.ajax({
    type:'POST',
    url: url,
    data: data,
    success: continuation,
    error: continuation,
    dataType: 'json'
  });
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
  getTotalClusterMemory: function () {
    return '??'; // TODO: implement
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

  var statsBucketURL = this.statsBucketURL = new Cell();
  watchHashParamChange("statsBucket", function (value) {
    statsBucketURL.setValue(value);
  });
  statsBucketURL.subscribeAny(function (cell) {
    console.log("cell.value:", cell.value);
    setHashFragmentParam("statsBucket", cell.value);
  });

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

var TrafficGen = {
  init: function () {
    BucketsSection.cells.detailedBuckets.subscribeAny(_.bind(this.updateUI, this, undefined));
    _.defer($m(this, 'updateUI'));
  },
  updateUI: function (forceRunning) {
    var running = forceRunning !== undefined ? forceRunning : this.isRunning();
    var isDefined = forceRunning !== undefined || (running != this.isNotRunning());

    if (!isDefined) {
      $('#test_cluster_block').hide();
    } else {
      $('#test_cluster_block').show();
      var className = running ? 'stop-active' : 'start-active';
      $('#test_cluster_start_stop').attr('class', className);

      $('#clear_test_data')[BucketsSection.findTGenBucket() ? 'show' : 'hide']();
    }
  },
  getControlURI: function () {
    var poolDetails = DAO.cells.currentPoolDetailsCell.value;
    return poolDetails && poolDetails.controllers.testWorkload.uri;
  },
  isRunning: function () {
    var tgenInfo = BucketsSection.findTGenBucket();
    return !!(tgenInfo && tgenInfo['status']);
  },
  isNotRunning: function () {
    var tgenInfo = BucketsSection.findTGenBucket();
    return tgenInfo !== undefined && (!tgenInfo || !tgenInfo['status']);
  },
  start: function () {
    if (!this.isRunning())
      this.startOrStop(true);
    else
      this.showTGenBucket();
  },
  showTGenBucket: function () {
    var tgenBucket = BucketsSection.findTGenBucket();
    if (tgenBucket)
      AnalyticsSection.visitBucket(tgenBucket.uri);
  },
  clearTestData: function () {
    BucketsSection.startFlushCache(BucketsSection.findTGenBucket().uri);
  },
  startOrStop: function (isStart) {
    var uri = this.getControlURI();
    if (!uri) {
      throw new Error('start() should not be called in this state!');
    }
    $.ajax({
      type:'POST',
      url:uri,
      data: 'onOrOff=' + (isStart ? 'on' : 'off'),
      success: continuation
    });
    this.updateUI(isStart);

    if (isStart) {
      var dialog = genericDialog({
        header: 'Starting...',
        text: 'Start request was sent. Awaiting server response.',
        buttons: {ok: false, cancel: false}
      });
    }

    function continuation() {
      BucketsSection.refreshBuckets(function () {
        if (!dialog) // do not bother if it was stop request
          return;

        dialog.close();

        TrafficGen.showTGenBucket();
      });
    }
  },
  toggleRunning: function () {
    this.startOrStop(this.isNotRunning());
  }
};

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
      reloadApp();
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
  var minX, minY = 1/0;
  var maxX, maxY = -1/0;
  var minInf = minY;
  var maxInf = maxY;

  var plotData = _.map(data, function (e, i) {
    if (e <= minY) {
      minX = i+1;
      minY = e;
    }
    if (e >= maxY) {
      maxX = i+1;
      maxY = e;
    }
    return [i+1, e];
  });

  $.plot(main,
         [{color: '#1d88ad',
           data: plotData}],
         {xaxis: {ticks:0, autoscaleMargin: 0.04},
          yaxis: {ticks:0, autoscaleMargin: 0.04},
          grid: {show:false},
          hooks: {draw: [drawMarkers]}});
  
  maybeReloadAppDueToLeak();

  function singleMarker(center, value) {
    var text;
    value = truncateTo3Digits(value);

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
  jq.find('.small_graph_label > .value').text(String(truncateTo3Digits(_.max(data))));

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
                    + "connection_structures cas_badval auth_cmds").split(' '),
  visibleStats: [],
  visibleStatsIsDirty: true,
  statNames: {},
  spinners: [],
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
  update: function () {
    var self = this;

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

    showDialog('analytics_settings_dialog', {
      onHide: function () {
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

    var memoryUtilization = 100-Math.round(freeMem*100/totalMem);

    var isCritical = memoryUtilization > 90;
    isCritical = isCritical || _.any(nodes, function (n) {
      return n.status != 'healthy';
    });

    var mcdMemReserved = 0;
    var mcdMemAllocd = 0;
    _.each(nodes, function (n) {
        mcdMemReserved += n.mcdMemoryReserved;
        mcdMemAllocd += n.mcdMemoryAllocated;
      });
    var mcdItemUtilization = Math.round((mcdMemAllocd/1048576)*100/mcdMemReserved);
    // TODO: need server-side help for second condition:
    // '2. server node in cluster has been or is unresponsive'

    var canJoinCluster = (nodes.length == 1);

    var statusData = {
      isCritical: isCritical,
      canJoinCluster: canJoinCluster,
      nodesCount: nodes.length,
      bucketsCount: buckets && buckets.length,
      memoryUtilization: memoryUtilization,
      memoryFreeMB: Math.floor(freeMem/1048576),
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

    showDialog('join_cluster_dialog', {
      onHide: function () {
        form.unbind('submit');
      }});
    form.bind('submit', function (e) {
      e.preventDefault();

      $('#join_cluster_dialog_errors_container').empty();
      var overlay = overlayWithSpinner(form);

      postWithValidationErrors('/node/controller/doJoinCluster', form, function (data, status) {
        overlay.remove();

        if (status != 'success') {
          renderTemplate('join_cluster_dialog_errors', data)
        } else {
          var user = form.find('[name=user]').val();
          var password = form.find('[name=password]').val();
          DAO.setAuthCookie(user, password);
          $.cookie('cluster_join_flash', '1');
          reloadApp();
        }
      })
    });
  },
  leaveCluster: function () {
    showDialog("eject_confirmation_dialog", {
      eventBindings: [['.save_button', 'click', function (e) {
        e.preventDefault();
        overlayWithSpinner('#eject_confirmation_dialog');
        $.ajax({
          type: 'POST',
          url: DAO.cells.currentPoolDetails.value.controllers.ejectNode.uri,
          data: "otpNode=Self",
          success: reloadAppNoArg,
          errors: reloadAppNoArg
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
        $.ajax({
          type: 'POST',
          url: DAO.cells.currentPoolDetails.value.controllers.ejectNode.uri,
          data: {otpNode: node.otpNode},
          error: reloadAppNoArg,
          success: reloadAppNoArg
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
  navClick: function () {
    DAO.cells.currentPoolDetailsCell.invalidate();
  },
  onEnter: function () {
    DAO.cells.currentPoolDetailsCell.invalidate();
  }
};

var BucketsSection = {
  cells: {},
  init: function () {
    var cells = this.cells;

    cells.firstPageDetailsURI = new Cell(function (poolDetails) {
      return poolDetails.buckets.uri;
    }).setSources({poolDetails: DAO.cells.currentPoolDetails});

    // by default copy first page uri, but we'll set it explicitly for pagination
    cells.detailsPageURI = new Cell(function (firstPageURI) {
      return firstPageURI;
    }).setSources({firstPageURI: cells.firstPageDetailsURI});

    cells.detailedBuckets = new Cell(function (pageURI) {
      return future.get({url: pageURI}, null, this.self.value);
    }).setSources({pageURI: cells.detailsPageURI});

    prepareTemplateForCell("bucket_list", cells.detailedBuckets);

    cells.detailedBuckets.subscribe($m(this, 'onBucketList'));
  },
  buckets: null,
  refreshBuckets: function (callback) {
    var cell = this.cells.detailedBuckets;
    if (callback) {
      cell.changedSlot.subscribeOnce(callback);
    }
    cell.invalidate();
  },
  onBucketList: function () {
    var buckets = this.buckets = this.cells.detailedBuckets.value;
    renderTemplate('bucket_list', buckets);
  },
  withBucket: function (uri, body) {
    var buckets = this.buckets || [];
    var bucketInfo = _.detect(buckets, function (info) {
      return info.uri == uri;
    });

    if (!bucketInfo) {
      console.log("Not found bucket for uri:", uri);
      return;
    }

    return body.call(this, bucketInfo);
  },
  findBucket: function (uri) {
    return this.withBucket(uri, function (r) {return r});
  },
  findTGenBucket: function () {
    if (!this.buckets)
      return;
    var rv = _.detect(this.buckets, function (info) {
      return info['testAppBucket'];
    });
    if (!rv)
      return null;
    return rv;
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
    this.onEnter();
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
        detailsText = " MB x " + nodesCnt + " server nodes = " + cacheValue * nodesCnt + "MB Total Cache Size/" + DAO.getTotalClusterMemory() + " Cluster Memory Available"
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
  },
  createSubmit: function () {
    var self = this;
    var form = $('#add_new_bucket_form');

    $('#add_new_bucket_errors_container').empty();
    var loading = overlayWithSpinner(form);

    postWithValidationErrors(self.cells.detailsPageURI.value, form, function (data, status) {
      loading.remove();
      if (status == 'error') {
        renderTemplate("add_new_bucket_errors", data);
      } else {
        self.cells.detailedBuckets.changedSlot.subscribeOnce(function () {
          self.finishCreate();
        });
        self.cells.detailedBuckets.recalculate();
      }
    });
  },
  startRemovingBucket: function () {
    if (!this.currentlyShownBucket)
      return;

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
    renderTemplate('alert_list', value.list);
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
      var params = {url: "/alerts", data: {}};
      return future.get(params, function (data) {
        if (value) {
          var newDataNumbers = _.pluck(data.list, 'number');
          _.each(value.list, function (oldItem) {
            if (!_.include(newDataNumbers, oldItem.number))
              data.list.push(oldItem);
          });
          data.list = data.list.slice(0, data.limit);
        }
        return data;
      }, this.self.value);
    }).setSources({active: this.active});
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
    renderTemplate('alert_logs', this.logs.value.list.reverse());
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
      var self = this;

      e.preventDefault();

      var dialog = genericDialog({
        header: 'Saving...',
        text: 'Saving settings, wait a bit',
        buttons: {ok: false, cancel: false}});

      var postData = $(self).serialize();

      postWithValidationErrors($(self).attr('action'), postData, function (data, status) {
        if (status != 'success') {
          alert("TODO: DESIGN\n" + data.join('\n'));
          return dialog.close();
        }

        reloadApp(function () {
          if (data && data.newBaseUri) {
            var uri = data.newBaseUri;
            if (uri.charAt(uri.length-1) == '/')
              uri = uri.slice(0, -1);
            return uri + document.location.pathname;
          }
        });
      });
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

    if (sec == 'overview')
      return;

    // prepend overview
    if (sec != 'settings')
      pushSection('overview');

    if (sec == 'analytics' && DAO.cells.statsBucketURL.value) {
      pushSection('buckets')
      var bucketInfo = DAO.cells.currentStatTargetCell.value;
      if (bucketInfo) {
        path.push([bucketInfo.name, null]);
      }
    } else
      pushSection(sec);

    var first = true;

    _.each(path.reverse(), function (pair) {
      var name = pair[0];
      var href = pair[1];

      var li = $('<li></li>');
      if (first) {
        first = false;
        li.text(name);
      } else {
        var a = $('<a></a>');
        a.attr('href', href);
        a.text(name);

        li.prepend(a);
      }

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
             analytics: AnalyticsSection,
             buckets: BucketsSection,
             alerts: AlertsSection,
             settings: SettingsSection},
  currentSection: null,
  currentSectionName: null,
  signOut: function () {
    $.cookie('auth', null);
    reloadApp();
  },
  gotoSection: function (section) {
    if (!(this.sections[section])) {
      throw new Error('unknown section:' + section);
    }
    if (this.currentSectionName == section && 'navClick' in this.currentSection)
      this.currentSection.navClick();
    else
      setHashFragmentParam('sec', section);
  },
  initialize: function () {
    _.each(_.values(this.sections), function (sec) {
      if (sec.init)
        sec.init();
    });
    TrafficGen.init();
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

      $('#mainPanel > div:not(.notice)').css('display', 'none');
      $('#'+sec).css('display','block');
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

    $('#auth_dialog .alert_red').show();
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
  if ($.cookie('cluster_join_flash')) {
    $.cookie('cluster_join_flash', null);
    displayNotice('You have successfully joined the cluster');
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
  var components = DAO.componentsVersion;
  $('#about_versions').text("Version: " + components['ns_server'] + ", Kernel: " + components['kernel']);
  showDialog('about_server_dialog');
}

(function () {
  var sentReports = 0;
  var ErrorReportsLimit = 8;

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
              errors: ignore});
    }, 500);
  }
  window.onerror = appOnError;
})();

function displayNotice(text) {
  var div = $('<div></div>');
  renderTemplate('notice', {text: text}, div.get(0));
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
