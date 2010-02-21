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
function Future(body, options) {
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
      if (async.action)
        async.action.finish();
      cell.deliverFutureValue(async, data);
    }
  },
  start: function (cell) {
    if (this.modal) {
      this.action = new ModalAction();
    }
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
  if (ajaxOptions.url === undefined)
    throw new Error("url is undefined");
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
  // forces cell recalculation unless async set is in progress
  // recalculate() call would abort and re-issue in-flight XHR
  // request, which is almost always bad thing
  dirty: function () {
    if (this.pendingFuture)
      return;
    this.recalculate();
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
