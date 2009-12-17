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

function mkMethodWrapper (method, superClass, methodName) {
  return function () {
    var args = $.makeArray(arguments);
    var _super = $m(this, methodName, superClass);
    args.unshift(_super);
    return method.apply(this, args);
  }
}

function mkClass(methods) {
  if (_.isFunction(methods)) {
    var superclass = methods;
    var origMethods = arguments[1];

    var meta = new Function();
    meta.prototype = superclass.prototype;

    methods = _.extend(new meta, origMethods);

    _.each(origMethods, function (method, methodName) {
      if (_.isFunction(method) && functionArgumentNames(method)[0] == '$super') {
        methods[methodName] = mkMethodWrapper(method, superclass, methodName);
      }
    });
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
  subscribeWithSlave: function (thunkOrSlave) {
    var slave;
    if (thunkOrSlave instanceof Slave)
      slave = thunkOrSlave;
    else
      slave = new Slave(thunkOrSlave);
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

function jsComparator(a,b) {
  return (a == b) ? 0 : ((a < b) ? -1 : 1);
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

// returns special value that when passed to Cell#setValue initiates async set
// 'body' is a function that's passed cell-generated dataCallback
// 'body' is assumed to arrange async process of computing/getting new value
// 'body' should arrange call to given dataCallback when new value is available, passing it this new value
// Value returned from body is ignored
//
// see future.get for usage example
function future(body, options) {
  return new Future(body, options);
}
var Future = function (body, options) {
  this.thunk = body;
  _.extend(this, options || {});
}
Future.prototype = {
  removeNowValue: function () {
    var rv = this.nowValue;
    delete this.nowValue;
    return rv;
  },
  mkCallback: function (cell) {
    var async = this;
    return function (data) {
      cell.deliverFutureValue(async, data);
    }
  },
  start: function (cell) {
    this.started = true;
    var thunk = this.thunk;
    this.thunk = undefined;
    thunk.call(cell.mkFormulaContext(), this.mkCallback(cell));
  }
};

future.get = function (ajaxOptions, valueTransformer, nowValue) {
  var options = {
    valueTransformer: valueTransformer,
    cancel: function () {
      xhr.abort();
    },
    nowValue: nowValue
  }
  var xhr;
  return future(function (dataCallback) {
    xhr = $.ajax(_.extend({type: 'GET',
                           dataType: 'json',
                           success: dataCallback},
                          ajaxOptions));
  }, options);
}

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
  equality: function (a, b) {
    return a == b;
  },
  subscribe: function (cb, options) {
    options = _.extend({'undefined': false,
                        changed: true}, options || {});
    var slave = new Slave(cb);
    if (options["undefined"])
      this.undefinedSlot.subscribeWithSlave(slave);
    if (options.changed)
      this.changedSlot.subscribeWithSlave(slave);
    return slave;
  },
  subscribeAny: function (cb) {
    return this.subscribe(cb, {'undefined': true});
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
      slot.subscribeAny($m(self, 'recalculate'));
    });

    var argumentSourceNames = this.argumentSourceNames = functionArgumentNames(this.formula);
    _.each(this.argumentSourceNames, function (a) {
      if (!(a in context))
        throw new Error('missing source named ' + a + ' which is required for formula:' + self.formula);
    });
    if (argumentSourceNames.length)
      this.effectiveFormula = this.mkEffectiveFormula();

    this.recalculate();
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
  // applies f to current cell value and extra arguments
  // and sets value to it's return value
  modifyValue: function (f) {
    var extra = _.toArray(arguments);
    extra.shift();
    this.setValue(f.apply(null, [this.value].concat(extra)));
  },
  setValue: function (newValue) {
    this.cancelAsyncSet();
    this.resetRecalculateAt();

    if (newValue instanceof Future) {
      var async = newValue;
      newValue = async.removeNowValue();
      this.pendingFuture = async;
      if (this.recalcGeneration != Cell.recalcGeneration) {
        this.recalcGeneration = Cell.recalcGeneration;
        Cell.asyncCells.push(this);
      }
    }

    var oldValue = this.value;
    if (this.beforeChangeHook)
      newValue = this.beforeChangeHook(newValue);
    this.value = newValue;

    if (newValue === undefined) {
      if (oldValue !== undefined)
        this.undefinedSlot.broadcast(this);
      return;
    }

    if (!this.equality(oldValue, newValue))
      this.changedSlot.broadcast(this);
  },
  // schedules cell value recalculation
  recalculate: function () {
    if (this.queuedValueUpdate)
      return;
    this.resetRecalculateAt();
    Cell.recalcCount++;
    _.defer($m(this, 'tryUpdatingValue'));
    this.queuedValueUpdate = true;
  },
  mkFormulaContext: function () {
    var context = {};
    _.each(this.context, function (cell, key) {
      context[key] = (key == 'self') ? cell : cell.value;
    });
    return context;
  },
  tryUpdatingValue: function () {
    var context = this.mkFormulaContext();
    try {
      var value = this.effectiveFormula.call(context);
      this.setValue(value);
    } finally {
      this.queuedValueUpdate = false;
      if (--Cell.recalcCount == 0)
        Cell.completeGeneration();
    }
  },
  deliverFutureValue: function (future, value) {
    // detect cancellation
    if (this.pendingFuture != future)
      return;

    this.pendingFuture = null;

    if (future.valueTransformer)
      value = (future.valueTransformer)(value);

    this.setValue(value);
  },
  cancelAsyncSet: function () {
    var async = this.pendingFuture;
    if (!async)
      return;
    this.pendingFuture = null;
    if (async.started && async.cancel) {
      try {
        async.cancel();
      } catch (e) {};
    }
  },
  resetRecalculateAt: function () {
    this.recalculateAtTime = undefined;
    if (this.recalculateAtTimeout)
      clearTimeout(this.recalculateAtTimeout);
    this.recalculateAtTimeout = undefined;
  },
  recalculateAt: function (time) {
    var self = this;

    if (time instanceof Date)
      time = time.valueOf();

    if (self.recalculateAtTime) {
      if (self.recalculateAtTime < time)
        return;
      clearTimeout(self.recalculateAtTimeout);
    }
    self.recalculateAtTime = time;

    var delay = time - (new Date()).valueOf();
    var f = $m(self, 'recalculate');

    if (delay <= 0)
      f();
    else
      // yes we re-check current time after delay
      // as I've seen few cases where browsers run callback earlier by few milliseconds
      self.recalculateAtTimeout = setTimeout(_.bind(this.recalculateAt, this, time), delay);
  }
});

_.extend(Cell, {
  asyncCells: [],
  recalcGeneration: {},
  recalcCount: 0,
  completeGeneration: function () {
    var asyncCells = this.asyncCells;
    this.asyncCells = [];
    this.recalcGeneration = {};
    var i, len = asyncCells.length;
    for (i = 0; i < len; i++) {
      var cell = asyncCells[i];
      var future = cell.pendingFuture;
      if (!future)
        continue;
      try {
        future.start(cell);
      } catch (e) {
        console.log("Got error trying to start future: ", e);
      }
    }
  }
})

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
  var firstTime = true;
  $(function () {
    $(window).bind('hashchange', function () {
      var newValue = $.bbq.getState(param) || defaultValue;
      if (!firstTime && oldValue == newValue)
        return;
      firstTime = false;
      oldValue = newValue;
      return callback.apply(this, [newValue].concat($.makeArray(arguments)));
    });
  });
}

var HashFragmentCell = mkClass(Cell, {
  initialize: function ($super, paramName, options) {
    $super();

    this.paramName = paramName;
    this.options = _.extend({
      firstValueIsDefault: false
    }, options || {});

    this.idToItems = {};
    this.items = [];
    this.defaultId = undefined;
    this.selectedId = undefined;
  },
  interpretState: function (id) {
    var item = this.idToItems[id];
    if (!item)
      return;

    this.setValue(item.value);
  },
  beforeChangeHook: function (value) {
    if (value === undefined) {
      var state = _.extend({}, $.bbq.getState());
      delete state[this.paramName];
      $.bbq.pushState(state, 2);

      this.selectedId = undefined;
      return value;
    }

    var pickedItem = _.detect(this.items, function (item) {
      return item.value == value;
    });
    if (!pickedItem)
      throw new Error("Aiiyee. Unknown value: " + value);

    this.selectedId = pickedItem.id;
    this.pushState(this.selectedId);

    return pickedItem.value;
  },
  // setValue: function (value) {
  //   var _super = $m(this, 'setValue', Cell);
  //   console.log('calling setValue: ', value, getBacktrace());
  //   return _super(value);
  // },
  pushState: function (id) {
    id = String(id);
    var currentState = $.bbq.getState(this.paramName);
    if (currentState == id || (currentState === undefined && id == this.defaultId))
      return;
    var obj = {};
    obj[this.paramName] = id;
    $.bbq.pushState(obj);
  },
  addItem: function (id, value, isDefault) {
    var item = {id: id, value: value, index: this.items.length};
    this.items.push(item);
    if (isDefault || (item.index == 0 && this.options.firstItemIsDefault))
      this.defaultId = id;
    this.idToItems[id] = item;
    return this;
  },
  finalizeBuilding: function () {
    watchHashParamChange(this.paramName, this.defaultId, $m(this, 'interpretState'));
    this.interpretState($.bbq.getState(this.paramName));
    return this;
  }
});

var LinkSwitchCell = mkClass(HashFragmentCell, {
  initialize: function ($super, paramName, options) {
    options = _.extend({
      selectedClass: 'selected',
      linkSelector: '*',
      eventSpec: 'click'
    }, options);

    $super(paramName, options);

    this.subscribeAny($m(this, 'updateSelected'));

    var self = this;
    $(self.options.linkSelector).live(self.options.eventSpec, function (event) {
      self.eventHandler(this, event);
    })
  },
  updateSelected: function () {
    $(_(this.idToItems).chain().keys().map($i).value()).removeClass(this.options.selectedClass);

    var value = this.value;
    if (value == undefined)
      return;

    var index = _.indexOf(_(this.items).pluck('value'), value);
    if (index < 0)
      throw new Error('invalid value!');

    var id = this.items[index].id;
    $($i(id)).addClass(this.options.selectedClass);
  },
  eventHandler: function (element, event) {
    var id = element.id;
    var item = this.idToItems[id];
    if (!item)
      return;

    this.pushState(id);
    event.preventDefault();
  },
  addLink: function (link, value, isDefault) {
    if (link.size() == 0)
      throw new Error('missing link for selector: ' + link.selector);
    var id = ensureElementId(link).attr('id');
    this.addItem(id, value, isDefault);
    return this;
  }
});

var TabsCell = mkClass(HashFragmentCell, {
  initialize: function ($super, paramName, tabsSelector, panesSelector, values, options) {
    var self = this;
    $super(paramName, options);

    self.tabsSelector = tabsSelector;
    self.panesSelector = panesSelector;
    var tabsOptions = $.extend({firstItemIsDefault: true},
                               options || {},
                               {api: true});
    self.api = $(tabsSelector).tabs(panesSelector, tabsOptions);

    self.api.onBeforeClick($m(this, 'onTabClick'));
    self.subscribeAny($m(this, 'updateSelected'));

    _.each(values, function (val, index) {
      self.addItem(index, val);
    });
    self.finalizeBuilding();
  },
  onTabClick: function (event, index) {
    var item = this.idToItems[index];
    if (!item)
      return;
    this.pushState(index);

    if (event.originalEvent)
      event.originalEvent.preventDefault();
  },
  updateSelected: function () {
    this.api.click(Number(this.selectedId));
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
    var samplesInterval = this.lastOps['samples_interval']*1000;
    return this.birthTime + (now + samplesInterval - 1 - this.birthTime)/samplesInterval*samplesInterval;
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

    var dataOffset = Math.round((tstamp - oldTstamp) / op.samples_interval)
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
      data.opsbysecond_start_tstamp = samplesRestorer.lastTstamp;
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
    graphZoomLevel: new LinkSwitchCell('graph_zoom',
                                       {firstItemIsDefault: true}),
    keysZoomLevel: new LinkSwitchCell('keys_zoom',
                                      {firstItemIsDefault: true}),
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
    var main = $('#overview_main_graph')
    var ops = $('#overview_graph_ops')
    var gets = $('#overview_graph_gets')
    var sets = $('#overview_graph_sets')
    var misses = $('#overview_graph_misses')

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
    DAO.cells.stats.subscribeAny($m(this, 'update'));

    var selected = this.selected;

    var ops = $('#overview_graph_ops');
    var gets = $('#overview_graph_gets');
    var sets = $('#overview_graph_sets');
    var misses = $('#overview_graph_misses');

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
  clearUI: function () {
    prepareRenderTemplate('top_keys', 'server_list', 'pool_list');
  },
  onKeyStats: function (cell) {
    renderTemplate('top_keys', $.map(cell.value.hot_keys, function (e) {
      return $.extend({}, e, {total: 0 + e.gets + e.misses});
    }));
  },
  onFreshNodeList: function () {
    var nodes = DAO.cells.currentPoolDetails.value.nodes;
//    debugger
    renderTemplate('server_list', nodes);
  },
  statRefreshOptions: {
    real_time: {channelPeriod: 1000, requestParam: 'now'},
    one_hr: {channelPeriod: 300000, requestParam: '1hr'},
    day: {channelPeriod: 1800000, requestParam: '24hr'}
  },
  init: function () {
    DAO.cells.stats.subscribe($m(this, 'onKeyStats'));
    DAO.cells.currentPoolDetails.subscribe($m(this, 'onFreshNodeList'));
    prepareTemplateForCell('top_keys', CurrentStatTargetHandler.currentStatTargetCell);
    prepareTemplateForCell('server_list', DAO.cells.currentPoolDetails);
    prepareTemplateForCell('pool_list', DAO.cells.poolList);

    _.each(this.statRefreshOptions, function (value, key) {
      DAO.cells.graphZoomLevel.addLink($('#overview_graph_zoom_' + key),
                                 value);
      DAO.cells.keysZoomLevel.addLink($('#overview_keys_zoom_' + key),
                                 value);
    });

    DAO.cells.graphZoomLevel.subscribe(function (cell) {
      var value = cell.value;
      DAO.cells.statsOptions.update({opspersecond_zoom: value.requestParam});
    });
    DAO.cells.graphZoomLevel.finalizeBuilding();

    DAO.cells.keysZoomLevel.subscribe(function (cell) {
      var value = cell.value;
      DAO.cells.statsOptions.update({
        keys_opspersecond_zoom: value.requestParam,
        keysInterval: value.channelPeriod
      });
    });
    DAO.cells.keysZoomLevel.finalizeBuilding();

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
