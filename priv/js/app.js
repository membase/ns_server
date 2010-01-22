//= require <jquery.js>
//= require <jqModal.js>
//= require <raphael.js>
//= require <g.raphael.js>
//= require <g.line.js>
//= require <jquery.ba-bbq.js>
// !not used!= require <jquery.jeditable.js>
//= require <underscore.js>
//= require <tools.tabs.js>
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
  var weekDays = "Sun Mon Tue Wen Thu Fri Sat".split(' ');
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
  alert("Either a network or server side error has occured.  The server has logged the error.  We will reload the console now to attempt to recover.");
  window.onUnexpectedXHRError = function () {}
  //reloadApp();
}

$.ajaxSetup({
  error: onUnexpectedXHRError,
  beforeSend: function (xhr) {
    if (DAO.login) {
      addBasicAuth(xhr, DAO.login, DAO.password);
    }
    xhr.setRequestHeader('Cache-Control', 'no-cache');
    xhr.setRequestHeader('Pragma', 'no-cache');
  }
});

var DAO = {
  ready: false,
  cells: {},
  onReady: function (thunk) {
    if (DAO.ready)
      thunk.call(null);
    else
      $(window).one('dao:ready', function () {thunk();});
  },
  switchSection: function (section) {
    DAO.cells.mode.setValue(section);
  },
  performLogin: function (login, password, callback) {
    this.login = login;
    this.password = password;

    var cb = function (data, status) {
      if (status == 'success') {
        DAO.ready = true;
        $(window).trigger('dao:ready');
        var rows = data.pools;
        DAO.cells.poolList.setValue(rows);
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
  }
};

(function () {
  this.mode = new Cell();
  this.poolList = new Cell();

  this.currentPoolDetailsCell = new Cell(function (poolList) {
    var uri = poolList[0].uri;
    return future.get({url: uri});
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

var SamplesRestorer = mkClass({
  initialize: function () {
    this.birthTime = (new Date()).valueOf();
  },
  nextSampleTime: function () {
    var now = (new Date()).valueOf();
    if (!this.lastOps)
      return now;
    var samplesInterval = this.lastOps['samplesInterval'];
    return this.birthTime + Math.floor((now + samplesInterval - 1 - this.birthTime)/samplesInterval)*samplesInterval;
  },
  transformOp: function (op) {
    var oldOps = this.lastOps;
    var ops = this.lastOps = op;
    var tstamp = this.lastTstamp = op.tstamp;
    if (!tstamp)
      return;

    var oldTstamp = this.lastTstamp;
    if (!this.lastTstamp || !oldOps)
      return;

    // if (op.misses.length == 0)
    //   alert("Got it!");

    var dataOffset = Math.round((tstamp - oldTstamp) / op['samplesInterval'])
    _.each(['misses', 'gets', 'sets', 'ops'], function (cat) {
      var oldArray = oldOps[cat];
      var newArray = ops[cat];

      var oldLength = oldArray.length;
      var nowLength = newArray.length;
      if (nowLength < oldLength)
        ops[cat] = oldArray.slice(-(oldLength-nowLength)-dataOffset,
                                  (dataOffset == 0) ? oldLength : -dataOffset).concat(newArray);
    });
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

    var isUpdate = false;
    if (samplesRestorer.lastTstamp) {
      isUpdate = true;
      data["opsbysecondStartTStamp"] = samplesRestorer.lastTstamp;
    }

    var valueTransformer = function (data) {
      samplesRestorer.transformOp(data.op);
      return data;
    }

    return future.get({
      url: target.stats.uri,
      data: data
    }, valueTransformer, isUpdate ? this.self.value : undefined);
  }).setSources({samplesRestorer: samplesRestorerCell,
                 options: statsOptionsCell,
                 target: targetCell});

  statsCell.subscribe(function (cell) {
    var at = cell.context.samplesRestorer.value.nextSampleTime();
    cell.recalculateAt(at);

    var keysInterval = statsOptionsCell.value.keysInterval;
    if (keysInterval)
      cell.recalculateAt((new Date()).valueOf() + keysInterval);
  });

  _.extend(DAO.cells, {
    stats: statsCell,
    statsOptions: statsOptionsCell,
    currentPoolDetails: DAO.cells.currentPoolDetailsCell
  });
})();

function renderTick(g, p1x, p1y, dx, dy, opts) {
  var p0x = p1x - dx;
  var p0y = p1y - dy;
  var p2x = p1x + dx;
  var p2y = p1y + dy;
  opts = _.extend({'stroke-width': 2},
                  opts || {});
  return g.path(["M", p0x, p0y,
                 "L", p2x, p2y].join(",")).attr(opts);
}

function renderLargeGraph(main, data) {
  var tick = renderTick;

  main.html("");
//  main.css("outline", "red solid 1px");
  var width = Math.min(main.parent().innerWidth(), 740);
  var height = 80;
  var paper = Raphael(main.get(0), width, height+20);

  var xs = _.map(data, function (_, i) {return i;});
  var yMax = _.max(data);
  paper.g.linechart(0, 0, width-25, height, xs, data,
                    {
                      gutter: 10,
                      minY: 0,
                      maxY: yMax*1.2,
                      colors: ['#a2a2a2'],
                      width: 1,
                      hook: function (h) {
                        // axis
                        var maxx = h.transformX(h.maxx);
                        var maxy = h.transformY(h.maxy);
                        var x0 = h.transformX(0);
                        var y0 = h.transformY(0);
                        h.paper.path(["M", x0, maxy,
                                      "L", x0, y0,
                                      "L", maxx, y0].join(","));
                        // axis marks
                        tick(h.paper, x0, maxy, 5, 0);
                        for (var i = 1; i <= 4; i++) {
                          tick(h.paper, h.transformX(h.maxx/4*i), y0, 0, 5);
                        }

                        var xMax = _.indexOf(data, yMax);
                        var yMin = _.min(data);
                        var xMin = _.indexOf(data, yMin);

                        tick(h.paper, h.transformX(xMax), h.transformY(yMax), 0, 10);
                        tick(h.paper, h.transformX(xMin), h.transformY(yMin), 0, 10);

                        // text
                        var maxText = h.paper.text(0, 0, yMax.toFixed(0)).attr({
                          font: "16px Arial, sans-serif",
                          'font-weight': 'bold',
                          fill: "blue"});
                        var bbox = maxText.getBBox();
                        maxText.translate(h.transformX(xMax) + 6 - bbox.x,
                                          h.transformY(yMax) - 9 - bbox.y);

                        var minText = h.paper.text(0, 0, yMin.toFixed(0)).attr({
                          font: "16px Arial, sans-serif",
                          'font-weight': 'bold',
                          fill: "red"});
                        var bbox = minText.getBBox();
                        minText.translate(h.transformX(xMin) + 6 - bbox.x,
                                          h.transformY(yMin) - 9 - bbox.y);
                      }
                    });
}

function renderSmallGraph(jq, data, text, isSelected) {
  jq.html("");
  jq.removeData('hover-rect');
//  jq.css("outline", "red solid 1px");

  var width = jq.innerWidth();
  var plotHeight = 80;
  var height = plotHeight+30+15;
  var paper = Raphael(jq.get(0), width, height);

  var xs = _.map(data, function (_, i) {return i;});

  var plotY = isSelected ? 20 : 30;
  paper.g.linechart(0, plotY, width, plotHeight, xs, data, {
    width: $.browser.msie ? 2 : 1,
    colors: ["#e2e2e2"]
  });
  var ymax = _.max(data).toFixed(0);
  paper.text(width/2, plotY + plotHeight/2, ymax).attr({
    font: "18px Arial, sans-serif",
    fill: "blue"
  });
  if (isSelected) {
    paper.text(width/2, 10, text).attr({
      font: "18px Arial, sans-serif"
    });
    paper.rect(1, 20, width-3, plotHeight+15-1).attr({
      'stroke-width': 2,
      'stroke': '#0099ff'
    });
  } else {
    paper.text(width/2, height-10, text).attr({
      font: "12px Arial, sans-serif"
    });
    var hoverRect = paper.rect(0, 30, width-1, plotHeight+15-1).attr({
      'stroke-width': 1,
      'stroke': '#0099ff'
    });
    hoverRect.hide();
    jq.data('hover-rect', hoverRect);
  }
}

var StatGraphs = {
  selected: new LinkSwitchCell('graph', {
    linkSelector: 'span',
    firstItemIsDefault: true}),
  selectedCounter: 0,
  renderNothing: function () {
    var main = $('#analytics_main_graph')
    var ops = $('#analytics_graph_ops')
    var gets = $('#analytics_graph_gets')
    var sets = $('#analytics_graph_sets')
    var misses = $('#analytics_graph_misses')

    prepareAreaUpdate(main);
    prepareAreaUpdate(ops);
    prepareAreaUpdate(gets);
    prepareAreaUpdate(sets);
    prepareAreaUpdate(misses);
  },
  update: function () {
    var cell = DAO.cells.stats;
    var stats = cell.value;
    if (!stats)
      return this.renderNothing();
    stats = stats.op;
    if (!stats)
      return this.renderNothing();

    var main = $('#analytics_main_graph')
    var ops = $('#analytics_graph_ops')
    var gets = $('#analytics_graph_gets')
    var sets = $('#analytics_graph_sets')
    var misses = $('#analytics_graph_misses')

    var selected = this.selected.value;

    renderLargeGraph(main, stats[selected]);

    renderSmallGraph(ops, stats.ops, "Ops per second",
                     selected == 'ops');
    renderSmallGraph(gets, stats.gets, "Gets per second",
                     selected == 'gets');
    renderSmallGraph(sets, stats.sets, "Sets per second",
                     selected == 'sets');
    renderSmallGraph(misses, stats.misses, "Misses per second",
                     selected == 'misses');
  },
  init: function () {
    DAO.cells.stats.subscribeAny($m(this, 'update'));

    var selected = this.selected;

    var ops = $('#analytics_graph_ops');
    var gets = $('#analytics_graph_gets');
    var sets = $('#analytics_graph_sets');
    var misses = $('#analytics_graph_misses');

    selected.addLink(ops, 'ops');
    selected.addLink(gets, 'gets');
    selected.addLink(sets, 'sets');
    selected.addLink(misses, 'misses');

    selected.subscribe($m(this, 'update'));
    selected.finalizeBuilding();

    var t = ops.add(gets).add(sets).add(misses);
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

function prepareTemplateForCell(templateName, cell) {
  cell.undefinedSlot.subscribeWithSlave(function () {
    prepareRenderTemplate(templateName);
  });
  if (cell.value === undefined)
    prepareRenderTemplate(templateName);
}

var OverviewSection = {
  onFreshNodeList: function () {
    var nodes = DAO.cells.currentPoolDetails.value.nodes;
    renderTemplate('server_list', nodes);
    $('#server_list_container table tr.primary:first-child').addClass('nbrdr');
    $('#get_started_expander').click(function() {
        if ($(this).hasClass('expanded'))
        {
            $(this).removeClass('expanded');
            $('#get_started').removeClass('block');
        } else {
            $(this).addClass('expanded');
            $('#get_started').addClass('block');
        }
    });
  },
  init: function () {
    DAO.cells.currentPoolDetails.subscribe($m(this, 'onFreshNodeList'));
    prepareTemplateForCell('server_list', DAO.cells.currentPoolDetails);
    prepareTemplateForCell('pool_list', DAO.cells.poolList);

  },
  onEnter: function () {
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
      return future.get({url: pageURI});
    }).setSources({pageURI: cells.detailsPageURI});

    prepareTemplateForCell("bucket_list", cells.detailedBuckets);

    cells.detailedBuckets.subscribe($m(this, 'onBucketList'));
  },
  buckets: [],
  onBucketList: function () {
    var buckets = this.buckets = this.cells.detailedBuckets.value;
    renderTemplate('bucket_list', buckets);
  },
  withBucket: function (uri, body) {
    var buckets = this.buckets;
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
      $.post(bucket.flushCacheURI);
    });
  },
  getPoolNodesCount: function () {
    return DAO.cells.currentPoolDetails.value.nodes.length;
  },
  onEnter: function () {
    this.cells.detailsPageURI.recalculate();
  },
  handlePasswordMatch: function (parent) {
    var passwd = parent.find("[name=password]").val();
    var passwd2 = parent.find("[name=verifyPassword]").val();
    var show = (passwd != passwd2);
    parent.find('.dont-match')[show ? 'show' : 'hide']();
    parent.find('[type=submit]').each(function () {
      if (show)
        this.setAttribute('disabled', 'disabled');
      else
        this.removeAttribute('disabled');
    });
    return !show;
  },
  checkFormChanges: function () {
    var parent = $('#add_new_bucket_dialog');
    this.handlePasswordMatch(parent);

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
    var res = $('#add_new_bucket_form').serialize();
    var self = this;

    $.ajax({
      type: 'POST',
      url: self.cells.detailsPageURI.value,
      data: res,
      success: continuation,
      error: continuation,
      dataType: 'json'
    });
    var modalAction = new ModalAction();
    var loading = overlayWithSpinner($('#add_new_bucket_form'));

    return;
    function continuation(data, textStatus) {
      modalAction.finish();
      loading.remove();

      if (textStatus == "error") {
        // jquery passes raw xhr object for errors
        if (data.status != 400) {
          return onUnexpectedXHRError(data);
        }

        data = $.httpData(data, this.dataType, this);
        renderTemplate("add_new_bucket_errors", data.errors);
      } else {
        self.finishCreate();
        self.cells.detailedBuckets.recalculate();
      }
    }
  },
  startPasswordChange: function () {
    var self = this;
    var form = $('#bucket_password_form');
    $("#bucket_password_form input[type=password]").val('');
    
    form.bind('submit', function (e) {
      e.preventDefault();
      $.post(self.currentlyShownBucket.passwordURI, form.serialize(), reloadApp);
    });
    var observer = form.observePotentialChanges(function () {
      self.handlePasswordMatch(form);
    })
    showDialog("bucket_password_dialog", {
      onHide: function () {
        observer.stopObserving();
        form.unbind();
      }});
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
      var names = $('.stat_target_name');
      names.text(cell.value.name);
    });
  },
  visitBucket: function (bucketURL) {
    DAO.cells.statsBucketURL.setValue(bucketURL);
    ThePage.gotoSection('analytics');
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
    $('#alerts_email_setting').text(checkboxValue(value.settings.sendAlerts) ? value.settings.email : 'nobody');
  },
  changeEmail: function () {
    this.alertTab.setValue('settings');
  },
  init: function () {
    this.active = new Cell(function (mode) {
      return (mode == "alerts") ? true : undefined;
    }).setSources({mode: DAO.cells.mode});

    this.alerts = new Cell(function (active) {
      var value = this.self.value;
      var params = {url: "/alerts", data: {}};
      if (value && value.list) {
        var number = value.list[value.list.length-1].number;
        if (number !== undefined)
          params.data.lastNumber = number;
      }
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
                                 "#alerts > .tabs",
                                 "#alerts > .panes > div",
                                 ["list", "settings", "log"]);

    $('#alerts_settings_form').bind('submit', $m(this, 'onSettingsSubmit'));
    this.alertTab.subscribe($m(this, 'onTabChanged'));
    this.onTabChanged();

    var sendAlerts = $('#alerts_settings_form [name=sendAlerts]');
    sendAlerts.bind('click', $m(this, 'onSendAlertsClick'));
  },
  onSendAlertsClick: function () {
    var sendAlerts = $('#alerts_settings_form [name=sendAlerts]');
    _.defer(function () {
      var show = sendAlerts.attr('checked');
      $('#alerts_settings_guts')[show ? 'show' : 'hide']();
    });
  },
  fillSettingsForm: function () {
    if ($('#alerts_settings_form_is_clean').val() != '1')
      return;

    // TODO: loading indicator here
    if (this.alerts.value === undefined) {
      this.alerts.changedSlot.subscribeOnce($m(this, 'fillSettingsForm'));
      return;
    }

    $('#alerts_settings_form_is_clean').val('0');

    var settings = _.extend({}, this.alerts.value.settings);
    delete settings.updateURI;

    _.each(settings, function (value, name) {
      var selector = '#alerts_settings_form [name=' + name + ']';
      var jq = $(selector);
      if (jq.attr('type') == 'checkbox') {
        jq = $(jq.get(0));
        if (value != '0')
          jq.attr('checked', 'checked');
        else
          jq.removeAttr('checked')
      } else
        $(selector).val(value);
    });

    this.onSendAlertsClick();
  },
  onTabChanged: function () {
    console.log("onTabChanged:", this.alertTab.value);
    if (this.alertTab.value == 'settings') {
      this.fillSettingsForm();
    }
  },
  onSettingsSubmit: function (event) {
    event.preventDefault();

    var form = $(event.target);

    var arrayForm = [];
    var hashForm = {};

    _.each(form.serializeArray(), function (pair) {
      if (hashForm[pair.name] === undefined) {
        hashForm[pair.name] = pair.value;
        arrayForm.push(pair);
      }
    });

    var stringForm = $.param(arrayForm);

    $.post(this.alerts.value.settings.updateURI, stringForm);

    $('#alerts_settings_form_is_clean').val('1');

    this.alerts.recalculate();
  },
  settingsCancel: function () {
    $('#alerts_settings_form_is_clean').val('1');
    this.fillSettingsForm();

    return false;
  },
  onEnter: function () {
  }
}

var DummySection = {
  onEnter: function () {}
};

var ThePage = {
  sections: {overview: OverviewSection,
             analytics: AnalyticsSection,
             buckets: BucketsSection,
             alerts: AlertsSection,
             settings: DummySection},
  currentSection: null,
  currentSectionName: null,
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

      $('#mainPanel > div').css('display', 'none');
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

var alreadyHadFailedLogin;

function loginFormSubmit() {
  var login = $('#login_form [name=login]').val();
  var password = $('#login_form [name=password]').val();
  var spinner = overlayWithSpinner('#login_form');
  DAO.performLogin(login, password, function (status) {
    spinner.remove();
    if (status == 'success') {
      hideDialog('login_dialog');
      return;
    }

    if (!alreadyHadFailedLogin)
      $('#login_form').prepend("<h1>Login failed. Try again</h1>")
    alreadyHadFailedLogin = true;
  });
  return false;
}

window.nav = {
  go: $m(ThePage, 'gotoSection')
};

$(function () {
  showDialog('login_dialog');

  _.defer(function () {
    $('#login_dialog [name=login]').get(0).focus();
  });

  ThePage.initialize();

  DAO.onReady(function () {
    $(window).trigger('hashchange');
  });

  $('#server_list_container .expander').live('click', function (e) {
    $('#server_list_container .expander').removeClass('expanded');
    var container = $('#server_list_container');
    var mydetails = $(e.target).parents("#server_list_container .primary").next();
    var opened = mydetails.hasClass('opened');

    container.find(".details").removeClass('opened');
    mydetails.toggleClass('opened', !opened);
    $(this).toggleClass('expanded', !opened);
  });
});

$(window).bind('template:rendered', function () {
    $('table.lined_tab tr:has(td):odd').addClass('highlight');
    $('table.hover_lines tr:has(td)').hover(
        function() {
            $(this).addClass('hovered');
        },
        function() {
            $(this).removeClass('hovered');
        }
    );
});