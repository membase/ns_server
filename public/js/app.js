if (!('console' in window))
  window.console = {log: function () {}};

function getBacktrace() {
  try {
    throw new Error();
  } catch (e) {
    return e.stack;
  }
};

function traceMethodCalls(object, methodName) {
  var original = object[methodName];
  var tracer = function() {
    var args = $.makeArray(arguments);
    console.log("traceIn:",object,".",methodName,"(",args,")");
    try {
      var rv = original.apply(this, arguments);
      console.log("traceOut: rv = ",rv);
      return rv;
    } catch (e) {
      console.log("traceExc: e = ", e);
      throw e;
    }
  }
  object[methodName] = tracer;
}

/**
*
*  Base64 encode / decode
*  http://www.webtoolkit.info/
*
**/
// ALK Note: we might want to rewrite this.
// webtoolkit.info license doesn't permit removal of comments which js minifiers do.
// also utf8 handling functions are not really utf8, but CESU-8.
// I.e. it doesn't handle utf16 surrogate pairs at all
var Base64 = {
 
	// private property
	_keyStr : "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=",
 
	// public method for encoding
	encode : function (input) {
		var output = "";
		var chr1, chr2, chr3, enc1, enc2, enc3, enc4;
		var i = 0;
 
		input = Base64._utf8_encode(input);
 
		while (i < input.length) {
 
			chr1 = input.charCodeAt(i++);
			chr2 = input.charCodeAt(i++);
			chr3 = input.charCodeAt(i++);
 
			enc1 = chr1 >> 2;
			enc2 = ((chr1 & 3) << 4) | (chr2 >> 4);
			enc3 = ((chr2 & 15) << 2) | (chr3 >> 6);
			enc4 = chr3 & 63;
 
			if (isNaN(chr2)) {
				enc3 = enc4 = 64;
			} else if (isNaN(chr3)) {
				enc4 = 64;
			}
 
			output = output +
			this._keyStr.charAt(enc1) + this._keyStr.charAt(enc2) +
			this._keyStr.charAt(enc3) + this._keyStr.charAt(enc4);
 
		}
 
		return output;
	},
 
	// public method for decoding
	decode : function (input) {
		var output = "";
		var chr1, chr2, chr3;
		var enc1, enc2, enc3, enc4;
		var i = 0;
 
		input = input.replace(/[^A-Za-z0-9\+\/\=]/g, "");
 
		while (i < input.length) {
 
			enc1 = this._keyStr.indexOf(input.charAt(i++));
			enc2 = this._keyStr.indexOf(input.charAt(i++));
			enc3 = this._keyStr.indexOf(input.charAt(i++));
			enc4 = this._keyStr.indexOf(input.charAt(i++));
 
			chr1 = (enc1 << 2) | (enc2 >> 4);
			chr2 = ((enc2 & 15) << 4) | (enc3 >> 2);
			chr3 = ((enc3 & 3) << 6) | enc4;
 
			output = output + String.fromCharCode(chr1);
 
			if (enc3 != 64) {
				output = output + String.fromCharCode(chr2);
			}
			if (enc4 != 64) {
				output = output + String.fromCharCode(chr3);
			}
 
		}
 
		output = Base64._utf8_decode(output);
 
		return output;
 
	},
 
	// private method for UTF-8 encoding
	_utf8_encode : function (string) {
//		string = string.replace(/\r\n/g,"\n");
		var utftext = "";
 
		for (var n = 0; n < string.length; n++) {
 
			var c = string.charCodeAt(n);
 
			if (c < 128) {
				utftext += String.fromCharCode(c);
			}
			else if((c > 127) && (c < 2048)) {
				utftext += String.fromCharCode((c >> 6) | 192);
				utftext += String.fromCharCode((c & 63) | 128);
			}
			else {
				utftext += String.fromCharCode((c >> 12) | 224);
				utftext += String.fromCharCode(((c >> 6) & 63) | 128);
				utftext += String.fromCharCode((c & 63) | 128);
			}
 
		}
 
		return utftext;
	},
 
	// private method for UTF-8 decoding
	_utf8_decode : function (utftext) {
		var string = "";
		var i = 0;
		var c = c1 = c2 = 0;
 
		while ( i < utftext.length ) {
 
			c = utftext.charCodeAt(i);
 
			if (c < 128) {
				string += String.fromCharCode(c);
				i++;
			}
			else if((c > 191) && (c < 224)) {
				c2 = utftext.charCodeAt(i+1);
				string += String.fromCharCode(((c & 31) << 6) | (c2 & 63));
				i += 2;
			}
			else {
				c2 = utftext.charCodeAt(i+1);
				c3 = utftext.charCodeAt(i+2);
				string += String.fromCharCode(((c & 15) << 12) | ((c2 & 63) << 6) | (c3 & 63));
				i += 3;
			}
 
		}
 
		return string;
	}
 
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

function escapeHTML() {
  return String(arguments[0]).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
}

// Based on: http://ejohn.org/blog/javascript-micro-templating/
// Simple JavaScript Templating
// John Resig - http://ejohn.org/ - MIT Licensed
;(function(){
  var cache = {};

  this.tmpl = function tmpl(str, data){
    // Figure out if we're getting a template, or if we need to
    // load the template - and be sure to cache the result.

    var fn = !/\W/.test(str) && (cache[str] = cache[str] ||
                                 tmpl(document.getElementById(str).innerHTML));

    if (!fn) {
      var body = "var p=[],print=function(){p.push.apply(p,arguments);}," +
        "h=window.escapeHTML;" +

      // Introduce the data as local variables using with(){}
      "with(obj){p.push('" +

      // Convert the template into pure JavaScript
      str
      .replace(/[\r\t\n]/g, " ")
      .split("{%").join("\t")
      .replace(/((^|%})[^\t]*)'/g, "$1\r") //'
      .replace(/\t=(.*?)%}/g, "',$1,'")
      .split("\t").join("');")
      .split("%}").join("p.push('")
      .split("\r").join("\\'")
        + "');}return p.join('');"

      // Generate a reusable function that will serve as a template
      // generator (and which will be cached).
      fn = new Function("obj", body);
    }

    // Provide some basic currying to the user
    return data ? fn( data ) : fn;
  };
})();

function addBasicAuth(xhr, login, password) {
  var auth = 'Basic ' + Base64.encode(login + ':' + password);
  xhr.setRequestHeader('Authorization', auth);
}

$.ajaxSetup({
  error: function () {
    alert("FIXME: network or server-side error happened! We'll handle it better in the future.");
  },
  beforeSend: function (xhr) {
    if (DAO.login) {
      addBasicAuth(xhr, DAO.login, DAO.password);
    }
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

$.isString = function (s) {
  return typeof(s) == "string" || (s instanceof String);
}

function prepareAreaUpdate(jq) {
  if ($.isString(jq))
    jq = $(jq);
  var height = jq.height();
  var width = jq.width();
  if (height < 50)
    height = 50;
  if (width < 100)
    width = 100;
  var replacement = $("<div class='spinner'><span>Loading...</span></div>", document);
  replacement.css('width', width + 'px').css('height', height + 'px').css('lineHeight', height + 'px');
  jq.html("");
  jq.append(replacement);
}

function prepareRenderTemplate() {
  $.each($.makeArray(arguments), function () {
    prepareAreaUpdate('#'+ this + '_container');
  });
}

function renderTemplate(key, data) {
  var to = key + '_container';
  var from = key + '_template';
  if ($.isArray(data)) {
    data = {rows:data};
  }
  $i(to).innerHTML = tmpl(from, data);
}

function __topEval() {
  return eval("(function () {return (" + String(arguments[0]) + ");})();");
}

function $m(self, method, klass) {
  if (klass) {
    var f = klass.prototype[method];
    if (!f || !f.apply)
      throw new Error("Bogus method: " + method + " on prototype of: " + klass);
  } else {
    var f = self[method];
    if (!f || !f.apply)
      throw new Error("Bogus method: " + method + " on object: " + self);
  }

  return function () {
    return f.apply(self, arguments);
  }
}

var $i = function (id) {
  return document.getElementById(id);
}

function mkClass(methods) {
  if (_.isFunction(methods)) {
    var superclass = methods;
    var origMethods = arguments[1];

    var meta = new Function();
    meta.prototype = superclass.prototype;

    methods = _.extend(new meta, origMethods);
  }

  var constructor = __topEval(function () {
    if (this.initialize)
      return this.initialize.apply(this, arguments);
  });

  constructor.prototype = methods;
  return constructor;
}

var Slave = mkClass({
  initialize: function (thunk) {
    this.thunk = thunk
  },
  die: function () {this.dead = true;},
  nMoreTimes: function (times) {
    this.times = this.times || 0;
    this.times += times;
    var oldThunk = this.thunk;
    this.thunk = function (data) {
      oldThunk.call(this, data);
      if (--this.times == 0)
        this.die();
    }
    return this;
  }
});

var CallbackSlot = mkClass({
  initialize: function () {
    this.slaves = [];
  },
  subscribeWithSlave: function (thunk) {
    var slave = new Slave(thunk);
    this.slaves.push(slave);
    return slave;
  },
  subscribeOnce: function (thunk) {
    return this.subscribeWithSlave(thunk).nMoreTimes(1);
  },
  broadcast: function (data) {
    var oldSlaves = this.slaves;
    var newSlaves = this.slaves = [];
    $.each(oldSlaves, function (index, slave) {
      slave.thunk(data);
      if (!slave.dead)
        newSlaves.push(slave);
    });
  },
  unsubscribe: function (slave) {
    slave.die();
    var index = $.inArray(slave, this.slaves);
    if (index >= 0)
      this.slaves.splice(index, 1);
  }
});

// stolen from MIT-licensed prototype.js http://www.prototypejs.org/
var functionArgumentNames = function(f) {
  var names = f.toString().match(/^[\s\(]*function[^(]*\(([^\)]*)\)/)[1]
                                 .replace(/\s+/g, '').split(',');
  return names.length == 1 && !names[0] ? [] : names;
};

// inspired in part by http://common-lisp.net/project/cells/
var Cell = mkClass({
  initialize: function (formula, sources) {
    this.changedSlot = new CallbackSlot();
    this.undefinedSlot = new CallbackSlot();
    this.formula = formula;
    this.effectiveFormula = formula;
    this.value = undefined;
    this.sources = [];
    this.argumentSourceNames = [];
    if (sources)
      this.setSources(sources);
  },
  queueValueUpdating: function () {
    if (this.queuedValueUpdate)
      return;
    _.defer($m(this, 'tryUpdatingValue'));
    this.queuedValueUpdate = true;
  },
  sourceUndefined: function (source) {
    var self = this;
    _.defer(function () {
      self.setValue(undefined);
    });
  },
  setSources: function (context) {
    var self = this;
    if (this.sources.length != 0)
      throw new Error('cannot adjust sources yet');
    if (!this.formula)
      throw new Error("formula-less cells cannot have sources");
    var slots = this.sources = _.values(context);
    this.context = _.extend({self: this}, context);
    if (_.any(slots, function (v) {return v == null;})) {
      var badSources = [];
      _.each(this.context, function (v, k) {
        if (!v)
          badSources.push(k);
      });
      throw new Error("null for following source cells: " + badSources.join(', '));
    }

    _.each(slots, function (slot) {
      slot.changedSlot.subscribeWithSlave($m(self, 'queueValueUpdating'))
      slot.undefinedSlot.subscribeWithSlave($m(self, 'queueValueUpdating'));
    });

    var argumentSourceNames = this.argumentSourceNames = functionArgumentNames(this.formula);
    _.each(this.argumentSourceNames, function (a) {
      if (!(a in context))
        throw new Error('missing source named ' + a + ' which is required for formula:' + self.formula);
    });
    if (argumentSourceNames.length)
      this.effectiveFormula = this.mkEffectiveFormula();

    this.tryUpdatingValue();

    return this;
  },
  mkEffectiveFormula: function () {
    var argumentSourceNames = this.argumentSourceNames;
    var formula = this.formula;
    return function () {
      var notOk = false;
      var self = this;
      var requiredValues = _.map(argumentSourceNames, function (a) {
        var rv = self[a];
        if (rv === undefined) {
          notOk = true;
//          return _.breakLoop();
        }
        return rv;
      });
      if (notOk)
        return;
      return formula.apply(this, requiredValues);
    }
  },
  setValue: function (newValue) {
    var oldValue = this.value;
    this.value = newValue;

    if (newValue === undefined) {
      if (oldValue !== undefined)
        this.undefinedSlot.broadcast(this);
      return;
    }

    if (oldValue != newValue)
      this.changedSlot.broadcast(this);
  },
  tryUpdatingValue: function () {
    this.queuedValueUpdate = false;
    var context = {};
    _.each(this.context, function (cell, key) {
      context[key] = (key == 'self') ? cell : cell.value;
    });
    var value = this.effectiveFormula.call(context);
    this.setValue(value);
  }
});

function ensureElementId(jq) {
  jq.each(function () {
    if (this.id)
      return;
    this.id = _.uniqueId('gen');
  });
  return jq;
}

function watchHashParamChange(param, defaultValue, callback) {
  if (!callback) {
    callback = defaultValue;
    defaultValue = undefined;
  }

  var oldValue;
  $(function () {
    $(window).bind('hashchange', function () {
      var newValue = $.bbq.getState(param) || defaultValue;
      if (oldValue !== undefined && oldValue == newValue)
        return;
      oldValue = newValue;
      return callback.apply(this, [newValue].concat($.makeArray(arguments)));
    });
  });
}

var LinkSwitchCell = mkClass(Cell, {
  initialize: function (paramName, options) {
    var _super = $m(this, 'initialize', Cell);
    _super();

    this.paramName = paramName;
    this.options = _.extend({
      selectedClass: 'selected',
      linkSelector: '*',
      eventSpec: 'click',
      clearOnChangesTo: [],
      firstLinkIsDefault: false
    }, options);

    this.resetLinks();

    var makeUndefinedOrDefault = $m(this, 'makeUndefinedOrDefault');
    // TODO: this is a bit broken for now
    // _.each(this.options.clearOnChangesTo, function (cell) {
    //   cell.changedSlot.subscribeWithSlave(makeUndefinedOrDefault);
    //   cell.undefinedSlot.subscribeWithSlave(makeUndefinedOrDefault);
    // });

    var updateSelected = $m(this, 'updateSelected');
    this.changedSlot.subscribeWithSlave(updateSelected);
    this.undefinedSlot.subscribeWithSlave(updateSelected);

    var self = this;
    $(self.options.linkSelector).live(self.options.eventSpec, function (event) {
      self.eventHandler(this, event);
    })
  },
  interpretState: function (id) {
    var item = this.idToLinks[id];
    if (!item)
      return;

    this.setValue(item.value);
    this.selectedId = id;
  },
  setValue: function (id) {
    var _super = $m(this, 'setValue', Cell);
    console.log('calling setValue: ', id, getBacktrace());
    return _super(id);
  },
  updateSelected: function () {
    $(_(this.idToLinks).chain().keys().map($i).value()).removeClass(this.options.selectedClass);

    var value = this.value;
    if (value == undefined)
      return;

    var index = _.indexOf(_(this.links).pluck('value'), value);
    if (index < 0)
      throw new Error('invalid value!');

    var id = this.links[index].id;
    $($i(id)).addClass(this.options.selectedClass);

    this.pushState(id);
  },
  pushState: function (id) {
    var obj = {};
    obj[this.paramName] = id;
    $.bbq.pushState(obj);
  },
  eventHandler: function (element, event) {
    var id = element.id;
    var item = this.idToLinks[id];
    if (!item)
      return;

    this.pushState(id);
    event.preventDefault();
  },
  makeUndefinedOrDefault: function () {
    if (this.defaultId)
      this.setValue(this.idToLinks[this.defaultId].value);
    else
      this.setValue(undefined);
  },
  resetLinks: function () {
    this.idToLinks = {};
    this.links = [];
    this.defaultId = undefined;
    this.selectedId = undefined;
  },
  addLink: function (link, value, isDefault) {
    if (link.size() == 0)
      throw new Error('missing link for selector: ' + link.selector);
    var id = ensureElementId(link).attr('id');
    var item = {id: id, value: value, index: this.links.length};
    this.links.push(item);
    if (isDefault || (item.index == 0 && this.options.firstLinkIsDefault))
      this.defaultId = id;
    this.idToLinks[id] = item;

    return this;
  },
  finalizeBuilding: function () {
    watchHashParamChange(this.paramName, this.defaultId, $m(this, 'interpretState'));
    this.interpretState($.bbq.getState(this.paramName));
    return this;
  }
});

var UpdatesChannel = mkClass({
  initialize: function (updateInitiator, period, plugged) {
    this.updateInitiator = updateInitiator;
    this.slot = new CallbackSlot();
    this.plugged = plugged ? 1 : 0;
    this.setPeriod(period);
  },
  setPeriod: function (period) {
    if (this.intervalHandle)
      clearInterval(this.intervalHandle);
    this.period = period;
    this.intervalHandle = setInterval($m(this, 'tickHandler'), this.period*1000);
    if (!this.updateIsInProgress)
      this.initiateUpdate();
  },
  tickHandler: function () {
    if (this.plugged)
      return;
    if (this.updateIsInProgress) {
      this.hadTickOverflow = true;
      return;
    }
    this.initiateUpdate();
  },
  updateSuccess: function (flag, data) {
    if (flag.cancelled)
      return;
    this.recentData = data;
    try {
      if (!this.plugged)
        this.slot.broadcast(this);
    } finally {
      this.updateComplete();
    }
  },
  updateComplete: function () {
    this.updateIsInProgress = false;
    if (this.hadTickOverflow) {
      this.hadTickOverflow = false;
      this.initiateUpdate();
    }
  },
  updateError: function (flag) {
    if (flag.cancelled)
      return;
    this.updateComplete();
  },
  initiateUpdate: function () {
    if (this.plugged)
      return;
    this.updateIsInProgress = {};
    this.updateInitiator(_.bind(this.updateSuccess, this, this.updateIsInProgress),
                         _.bind(this.updateError, this, this.updateIsInProgress));
  },
  plug: function (cancelCurrentUpdate) {
    if (cancelCurrentUpdate && this.updateIsInProgress) {
      this.updateIsInProgress.cancelled = true;
      this.hadTickOverflow = false;
      this.updateIsInProgress = false;
    }
    if (this.plugged++ != 0)
      return;
    if (this.intervalHandle)
      clearInterval(this.intervalHandle);
  },
  unplug: function () {
    if (--this.plugged != 0)
      return;
    this.setPeriod(this.period);
  }
});

var baseDelegator = mkClass({
  initialize: function (target) {
    this.target = target;
  }
});

function mkDelegator(klass, base) {
  base = base || baseDelegator;

  var proto = klass.prototype;
  var methods = {};
  _.each(_.keys(proto), function (name) {
    if (name in base.prototype)
      return;
    methods[name] = function () {
      return proto[name].apply(this.target, arguments);
    };
  });

  return mkClass(base, methods);
}

var CellControlledUpdateChannel = mkClass(UpdatesChannel, {
  initialize: function (cell, period) {
    var _super = $m(this, 'initialize', UpdatesChannel);
    _super($m(this, 'updateInitiator'), period, true);
    this.cell = cell;
    this.cell.changedSlot.subscribeWithSlave($m(this, 'onCellChanged'));
    this.cell.undefinedSlot.subscribeWithSlave($m(this, 'onCellUndefined'));
    this.pluggedViaCell = true;
    this.extraXHRData = {};
  },
  onCellChanged: function () {
    if (!this.pluggedViaCell)
      this.plug(true);
    this.pluggedViaCell = false;
    this.unplug();
  },
  onCellUndefined: function () {
    this.pluggedViaCell = true;
    this.plug(true);
  },
  updateInitiator: function (okCallback, errorCallback) {
    $.ajax(_.extend({type: 'GET',
                     dataType: 'json',
                     success: okCallback,
                     data: _.extend(this.extraXHRData, this.cell.value.data || {}),
                     error: errorCallback},
                    this.cell.value));
  }
});

(function () {
  var Base = mkDelegator(UpdatesChannel);
  window.StatUpdateSubchannel = mkClass(Base, {
    initialize: function (mainChannel) {
      $m(this, 'initialize', Base)(mainChannel);

      mainChannel.subchannels = (mainChannel.subchannels || []);
      mainChannel.subchannels.push(this);

      this.slot = this.target.slot;
      this.period = 1/0;
    },
    setPeriod: function (period) {
      this.period = period;
      period = _.min(_.pluck(this.target.subchannels, 'period'));
      if (period != this.target.period)
        $m(this, 'setPeriod', Base)(period);
    },
    setXHRExtra: function (options) {
      this.target.extraXHRData = _.extend(this.target.extraXHRData, options);
    }
  });
})()

var OpsStatUpdateSubchannel = mkClass(StatUpdateSubchannel, {
  initialize: function (mainChannel) {
    $m(this, 'initialize', StatUpdateSubchannel)(mainChannel);

    this.slot.subscribeWithSlave($m(this, 'onDataArrived'));
  },
  onDataArrived: function () {
    var oldOps = this.lastOps;
    var ops = this.lastOps = this.target.recentData.op;
    var tstamp = this.lastTstamp = this.target.recentData.op.tstamp;
    if (!tstamp)
      return;

    this.setXHRExtra({opsbysecond_start_tstamp: tstamp});

    var oldTstamp = this.lastTstamp;
    if (!this.lastTstamp || !oldOps)
      return;

    var dataOffset = Math.round((tstamp - oldTstamp) / this.target.recentData.op.samples_interval)
    _.each(['misses', 'gets', 'sets', 'ops'], function (cat) {
      var oldArray = oldOps[cat];
      var newArray = ops[cat];

      var oldLength = oldArray.length;
      var nowLength = newArray.length;
      if (nowLength < oldLength)
        ops[cat] = oldArray.slice(-(oldLength-nowLength)-dataOffset, (dataOffset == 0) ? oldLength : -dataOffset).concat(newArray);
    });
  }
});

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

// TODO: need special ajax valued cell type so that we can avoid DoS-ing
// server with duplicate requests
function asyncAjaxCellValue(cell, options) {
  $.ajax(_.extend({type: 'GET',
                   dataType: 'json',
                   success: function (data) {
                     cell.setValue(data);
                   }},
                 options));
}

(function () {
  var modeCell = new Cell();
  var poolListCell = new Cell();
  var overviewActive = new Cell(function () {return this.mode == 'overview'},
                                {mode: modeCell});

  DAO.cells = {
    mode: modeCell,
    overviewActive: overviewActive,
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
      asyncAjaxCellValue(this.self, {url: uri});
    }).setSources({currentPoolIndex: this.currentPoolIndexCell, poolList: DAO.cells.poolList});

    this.currentBucketIndexCell = new Cell(function (path, currentPoolDetails) {
      var index = path.bucketNumber;
      if (index == undefined)
        return;

      if (index < 0)
        index = 0;
      if (index >= currentPoolDetails.bucket.length)
        index = currentPoolDetails.bucket.length - 1;
      return index;
    }).setSources({path: this.pathCell, currentPoolDetails: this.currentPoolDetailsCell});

    this.currentBucketDetailsCell = new Cell(function (currentBucketIndex, currentPoolDetails) {
      asyncAjaxCellValue(this.self, {url: currentPoolDetails.bucket[currentBucketIndex].uri});
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

    this.currentPoolIndexCell.changedSlot.subscribeWithSlave($m(this, 'renderPoolList'));
    this.currentPoolDetailsCell.changedSlot.subscribeWithSlave($m(this, 'renderBucketList'));

    $('a').live('click', $m(this, 'clickHandler'));

    this.pathCell.changedSlot.subscribeWithSlave($m(this, 'markSelected'));
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

    var list = this.currentPoolDetailsCell.value.bucket;
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

(function () {
  var targetCell = CurrentStatTargetHandler.currentStatTargetCell;

  var StatsArgsCell = new Cell(function (target) {
    return {url: target.stats.uri};
  }).setSources({target: targetCell});
  var StatsChannel = new CellControlledUpdateChannel(StatsArgsCell, 86400);

  var opStatsSubchannel = new OpsStatUpdateSubchannel(StatsChannel);
  var keyStatsSubchannel = new StatUpdateSubchannel(StatsChannel);

  _.extend(DAO.cells, {
    graphZoomLevel: new LinkSwitchCell('graph_zoom',
                                       {firstLinkIsDefault: true,
                                        clearOnChangesTo: [DAO.cells.overviewActive]}),
    keysZoomLevel: new LinkSwitchCell('keys_zoom',
                                      {firstLinkIsDefault: true,
                                       clearOnChangesTo: [DAO.cells.overviewActive]}),
    currentPoolDetails: CurrentStatTargetHandler.currentPoolDetailsCell
  });
  DAO.channels = {
    statsMain: StatsChannel,
    opStats: opStatsSubchannel,
    keyStats: keyStatsSubchannel
  }
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
    width: 1,
    colors: ["#e2e2e2"]
  });
  paper.text(width/2, plotY + plotHeight/2, _.max(data)).attr({
    font: "18px Arial, sans-serif",
    fill: "blue"
  });
  if (isSelected) {
    paper.text(width/2, 10, text).attr({
      font: "18px Arial, sans-serif"
    });
    paper.rect(1, 20, width-2, plotHeight+15-1).attr({
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
    firstLinkIsDefault: true}),
  selectedCounter: 0,
  update: function () {
    var stats = DAO.channels.statsMain.recentData;
    if (!stats)
      return;
    stats = stats.op;
    if (!stats)
      return;

    var main = $('#overview_main_graph')
    var ops = $('#overview_graph_ops')
    var gets = $('#overview_graph_gets')
    var sets = $('#overview_graph_sets')
    var misses = $('#overview_graph_misses')

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
    var selected = this.selected;

    var ops = $('#overview_graph_ops');
    var gets = $('#overview_graph_gets');
    var sets = $('#overview_graph_sets');
    var misses = $('#overview_graph_misses');

    selected.addLink(ops, 'ops');
    selected.addLink(gets, 'gets');
    selected.addLink(sets, 'sets');
    selected.addLink(misses, 'misses');

    selected.changedSlot.subscribeWithSlave($m(this, 'update'));
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
  clearUI: function () {
    prepareRenderTemplate('top_keys', 'server_list', 'pool_list');
  },
  onFreshStats: function () {
    StatGraphs.update()
  },
  onKeyStats: function (channel) {
    renderTemplate('top_keys', $.map(channel.recentData.hot_keys, function (e) {
      return $.extend({}, e, {total: 0 + e.gets + e.misses});
    }));
  },
  onFreshNodeList: function () {
    var nodes = DAO.cells.currentPoolDetails.value.node;
    renderTemplate('server_list', nodes);
  },
  statRefreshOptions: {
    real_time: {channelPeriod: 1, requestParam: 'now'},
    one_hr: {channelPeriod: 300, requestParam: '1hr'},
    day: {channelPeriod: 1800, requestParam: '24hr'}
  },
  init: function () {
    DAO.channels.opStats.slot.subscribeWithSlave($m(this, 'onFreshStats'));
    DAO.channels.keyStats.slot.subscribeWithSlave($m(this, 'onKeyStats'));
    DAO.cells.currentPoolDetails.changedSlot.subscribeWithSlave($m(this, 'onFreshNodeList'));
    prepareTemplateForCell('top_keys', CurrentStatTargetHandler.currentStatTargetCell);
    prepareTemplateForCell('server_list', DAO.cells.currentPoolDetails);    
    prepareTemplateForCell('pool_list', DAO.cells.poolList);

    _.each(this.statRefreshOptions, function (value, key) {
      DAO.cells.graphZoomLevel.addLink($('#overview_graph_zoom_' + key),
                                 value);
      DAO.cells.keysZoomLevel.addLink($('#overview_keys_zoom_' + key),
                                 value);
    });

    DAO.cells.graphZoomLevel.changedSlot.subscribeWithSlave(function (cell) {
      var value = cell.value;
      var channel = DAO.channels.opStats;

      channel.plug(true);
      channel.setXHRExtra({opspersecond_zoom: value.requestParam});
      channel.setPeriod(value.channelPeriod);
      channel.unplug();
    });
    DAO.cells.graphZoomLevel.finalizeBuilding();

    DAO.cells.keysZoomLevel.changedSlot.subscribeWithSlave(function (cell) {
      var value = cell.value;
      var channel = DAO.channels.keyStats;

      channel.plug(true);
      channel.setXHRExtra({keys_opspersecond_zoom: value.requestParam});
      channel.setPeriod(value.channelPeriod);
      channel.unplug();
    });
    DAO.cells.keysZoomLevel.finalizeBuilding();

    StatGraphs.init();
  },
  onEnter: function () {
  }
};

var DummySection = {
  onEnter: function () {}
};

var ThePage = {
  sections: {overview: OverviewSection,
             alerts: DummySection,
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
