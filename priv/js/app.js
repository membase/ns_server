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

$.ajaxSetup({
  error: function () {
    alert("Either a network or server side error has occured.  The server has logged the error.  We will reload the console now to attempt to recover.");
  },
  beforeSend: function (xhr) {
    if (DAO.login) {
      addBasicAuth(xhr, DAO.login, DAO.password);
    }
    xhr.setRequestHeader('Cache-Control', 'no-cache');
    xhr.setRequestHeader('Pragma', 'no-cache');
  }
});

function deferringUntilReady(body) {
  return function () {
    if (DAO.ready) {
      body.apply(this, arguments);
      return;
    }
    var self = this;
    var args = arguments;
    DAO.onReady(function () {
      body.apply(self, args);
    });
  }
}

function deeperEquality(a, b) {
  var typeA = typeof(a);
  var typeB = typeof(b);
  if (typeA != typeB)
    return false;
  var keysA = _.keys(a);
  var keysUnion = _.uniq(_.keys(b).sort(jsComparator), true);
  if (keysA.length != keysUnion.length)
    return false;

  for (var key in a)
    if (a[key] != b[key])
      return false;

  return true;
}

// ---

var DAO = {
  ready: false,
  onReady: function (thunk) {
    if (DAO.ready)
      thunk.call(null);
    else
      $(window).one('dao:ready', function () {thunk();});
  },
  switchSection: function (section) {
    DAO.cells.mode.setValue(section);
  },
  performLogin: function (login, password) {
    this.login = login;
    this.password = password;
    $.get('/pools', null, function (data) {
      DAO.ready = true;
      $(window).trigger('dao:ready');
      var rows = data.pools;
      DAO.cells.poolList.setValue(rows);
    }, 'json');
  }
};

(function () {
  var modeCell = new Cell();
  var poolListCell = new Cell();

  DAO.cells = {
    mode: modeCell,
    poolList: poolListCell
  }
})();

var CurrentStatTargetHandler = {
  initialize: function () {
    watchHashParamChange("stat_target", $m(this, 'targetURIChanged'));

    var poolListCell = DAO.cells.poolList;

    this.pathCell = new Cell();
    this.currentPoolIndexCell = new Cell(function (path, poolList) {
      var index = path.poolNumber;
      if (index < 0)
        index = 0;
      if (index >= poolList.length)
        index = poolList.length - 1;
      return index;
    }).setSources({path: this.pathCell, poolList: poolListCell});

    this.currentPoolDetailsCell = new Cell(function (currentPoolIndex, poolList) {
      console.log("currentPoolDetailsCell: (",currentPoolIndex,poolList,")")
      var uri = poolList[currentPoolIndex].uri;
      return future.get({url: uri});
    }).setSources({currentPoolIndex: this.currentPoolIndexCell, poolList: DAO.cells.poolList});

    this.currentBucketIndexCell = new Cell(function (path, currentPoolDetails) {
      var index = path.bucketNumber;
      if (index == undefined)
        return;

      if (index < 0)
        index = 0;
      if (index >= currentPoolDetails.buckets.length)
        index = currentPoolDetails.buckets.length - 1;
      return index;
    }).setSources({path: this.pathCell, currentPoolDetails: this.currentPoolDetailsCell});

    this.currentBucketDetailsCell = new Cell(function (currentBucketIndex, currentPoolDetails) {
      return future.get({url: currentPoolDetails.buckets[currentBucketIndex].uri});
    }).setSources({currentBucketIndex: this.currentBucketIndexCell,
                   currentPoolDetails: this.currentPoolDetailsCell});

    this.currentStatTargetCell = new Cell(function (path) {
      console.log('currentStatTargetCell');
      if (path.bucketNumber != null)
        return this.currentBucketDetails;
      else
        return this.currentPoolDetails;
    }).setSources({path: this.pathCell,
                   currentPoolDetails: this.currentPoolDetailsCell,
                   currentBucketDetails: this.currentBucketDetailsCell});

    this.currentPoolIndexCell.subscribe($m(this, 'renderPoolList'));
    this.currentPoolDetailsCell.subscribe($m(this, 'renderBucketList'));

    $('a').live('click', $m(this, 'clickHandler'));

    this.pathCell.subscribe($m(this, 'markSelected'));
  },
  targetURIChanged: function (value) {
    var arr = value ? value.split("/") : ['0'];
    this.pathCell.setValue({poolNumber: parseInt(arr[0], 10),
                            bucketNumber: arr[1] ? parseInt(arr[1], 10) : undefined});
  },
  renderPoolList: function () {
    var list = DAO.cells.poolList.value;
    
    var counter = 0;
    var register = function (row) {
      var id = 'pl_' + (counter++);
      return id;
    }

    renderTemplate('pool_list', {rows: list, register: register});
    _.defer($m(this, 'markSelected'));
  },
  renderBucketList: function () {
    console.log("renderBucketList");
    $('bucket_list').remove();

    var poolNumber = this.pathCell.value.poolNumber
    var poolID = "pl_" + poolNumber;

    var counter = 0;
    var register = function () {
      return 'bt_' + poolNumber + '_' + (counter++);
    }

    var list = this.currentPoolDetailsCell.value.buckets;
    var html = $(tmpl('bucket_list_template', {rows: list, register: register}));
    $($i(poolID)).parent().append(html);
    _.defer($m(this, 'markSelected'));
  },
  markSelected: function () {
    $('[id^=bt_]').removeClass('selected');
    $('[id^=pl_]').removeClass('selected');

    var path = this.pathCell.value;
    if (!path)
      return;

    if (path.bucketNumber !== undefined)
      var selectedID = 'bt_' + path.poolNumber + '_' + path.bucketNumber;
    else
      var selectedID = 'pl_' + path.poolNumber;

    var element = $i(selectedID);

    $(element).addClass('selected');
  },
  clickHandler: function (event) {
    var id = event.target.id;
    if (!id)
      return;

    var prefix = id.substring(0, 3);
    if (prefix != 'pl_' && prefix != 'bt_')
      return;

    event.preventDefault();

    var arr = id.split('_');
    if (prefix == 'pl_')
      $.bbq.pushState({stat_target: arr[1]});
    else
      $.bbq.pushState({stat_target: arr[1] + '/' + arr[2]});
  }
};

CurrentStatTargetHandler.initialize();

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
  var targetCell = CurrentStatTargetHandler.currentStatTargetCell;

  var StatsArgsCell = new Cell(function (target) {
    return {url: target.stats.uri};
  }).setSources({target: targetCell});

  var statsOptionsCell = new Cell();
  statsOptionsCell.setValue({nonQ: ['keysInterval', 'nonQ']});
  _.extend(statsOptionsCell, {
    update: function (options) {
      this.modifyValue(_.bind($.extend, $, {}), options);
    },
    equality: deeperEquality
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
    currentPoolDetails: CurrentStatTargetHandler.currentPoolDetailsCell
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
}

var OverviewSection = {
  onFreshNodeList: function () {
    var nodes = DAO.cells.currentPoolDetails.value.nodes;
    renderTemplate('server_list', nodes);
  },
  init: function () {
    DAO.cells.currentPoolDetails.subscribe($m(this, 'onFreshNodeList'));
    prepareTemplateForCell('server_list', DAO.cells.currentPoolDetails);
    prepareTemplateForCell('pool_list', DAO.cells.poolList);

  },
  onEnter: function () {
  }
};

var AnalyticsSection = {
  onKeyStats: function (cell) {
    renderTemplate('top_keys', $.map(cell.value.hot_keys, function (e) {
      return $.extend({}, e, {total: 0 + e.gets + e.misses});
    }));
  },
  init: function () {
    DAO.cells.stats.subscribe($m(this, 'onKeyStats'));
    prepareTemplateForCell('top_keys', CurrentStatTargetHandler.currentStatTargetCell);

    DAO.cells.statsOptions.update({
      "keysOpsPerSecondZoom": 'now',
      "keysInterval": 5000
    });

    StatGraphs.init();

    CurrentStatTargetHandler.currentStatTargetCell.subscribe(function (cell) {
      var names = $('.stat_target_name');
      names.text(cell.value.name);
    });
  },
  onEnter: function () {
    StatGraphs.update();
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
             buckets: DummySection,
             alerts: AlertsSection,
             settings: DummySection},
  currentSection: null,
  currentSectionName: null,
  gotoSection: function (section) {
    if (!(this.sections[section])) {
      throw new Error('unknown section:' + section);
    }
    $.bbq.pushState({sec: section});
  },
  initialize: function () {
    OverviewSection.init();
    AnalyticsSection.init();
    AlertsSection.init();
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

      $('#middle_pane > div').css('display', 'none');
      $('#'+sec).css('display','block');
      setTimeout(function () {
        if (oldSection && oldSection.onLeave)
          oldSection.onLeave();
        self.currentSection.onEnter();
        $(window).trigger('sec:' + sec);
      }, 10);
    });
  }
};

function loginFormSubmit() {
  var login = $('#login_form [name=login]').val();
  var password = $('#login_form [name=password]').val();
  DAO.performLogin(login, password);
  $(window).one('dao:ready', function () {
    $('#login_dialog').jqmHide();
  });
  return false;
}

window.nav = {
  go: $m(ThePage, 'gotoSection')
};

$(function () {
  $('#login_dialog').jqm({modal: true}).jqmShow();

  // TMP TMP
  _.defer(function () {
    $('#login_form input').val('admin');
    loginFormSubmit();
  });

  setTimeout(function () {
    $('#login_dialog [name=login]').get(0).focus();
  }, 100);

  ThePage.initialize();

  DAO.onReady(function () {
    $(window).trigger('hashchange');
  });

  $('#server_list_container .expander').live('click', function (e) {
    var container = $('#server_list_container');

    var mydetails = $(e.target).parents("#server_list_container .primary").next();
    var opened = mydetails.hasClass('opened');

    container.find(".details").removeClass('opened');
    mydetails.toggleClass('opened', !opened);
  });
});
