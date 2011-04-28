/**
   Copyright 2011 Couchbase, Inc.

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
  constructor: Future,
  cancelled: false,
  removeNowValue: function () {
    var rv = this.nowValue;
    delete this.nowValue;
    return rv;
  },
  mkCallback: function (cell) {
    var async = this;
    var rv = function (data) {
      if (async.action)
        async.action.finish();
      return cell.deliverFutureValue(async, data);
    }
    rv.async = async;
    rv.cell = cell;
    rv.continuing = function (data) {
      async.nowValue = data;
      return rv(async);
    }
    return rv;
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

// inspired in part by http://common-lisp.net/project/cells/
var Cell = mkClass({
  initialize: function (formula, sources) {
    this.changedSlot = new CallbackSlot();
    this.undefinedSlot = new CallbackSlot();
    this.dependenciesSlot = new CallbackSlot();
    this.formula = formula;
    this.effectiveFormula = formula;
    this.value = undefined;
    this.sources = [];
    this.context = {};
    this.argumentSourceNames = [];
    if (sources)
      this.setSources(sources);
    else if (this.formula)
      this.recalculate();
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
  subscribeOnUndefined: function (cb) {
    return this.subscribe(cb, {'undefined': true, changed: false});
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
    var cells = this.sources = _.values(context);
    this.context = _.extend({self: this}, context);
    if (_.any(cells, function (v) {return v == null;})) {
      var badSources = [];
      _.each(this.context, function (v, k) {
        if (!v)
          badSources.push(k);
      });
      throw new Error("null for following source cells: " + badSources.join(', '));
    }

    var recalculate = $m(self, 'recalculate');
    _.each(cells, function (cell) {
      cell.dependenciesSlot.subscribeWithSlave(recalculate);
    });

    self.boundRecalculate = recalculate;

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
  getSourceCells: function () {
    return this.sources;
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
    var extra = _.rest(arguments);
    this.setValue(f.apply(null, [this.value].concat(extra)));
  },
  _markForCompletion: function () {
    if (Cell.recalcCount == 0) {
      Cell.completeCellDelay(this);
      return;
    }

    if (this.recalcGeneration != Cell.recalcGeneration) {
      this.recalcGeneration = Cell.recalcGeneration;
      Cell.updatedCells.push(this);
    }
  },
  isValuesDiffer: function (oldValue, newValue) {
    if (newValue === undefined) {
      if (oldValue == undefined)
        return false;
    } else {
      if (oldValue !== undefined && this.equality(oldValue, newValue))
        return false;
    }

    return true;
  },
  setValue: function (newValue) {
    this.cancelAsyncSet();
    this.resetRecalculateAt();

    if (newValue instanceof Future) {
      var async = newValue;
      if (this.keepValueDuringAsync) {
        newValue = this.value;
      } else {
        newValue = async.removeNowValue();
      }
      this.pendingFuture = async;
      this._markForCompletion();
    }

    var oldValue = this.value;
    if (this.beforeChangeHook)
      newValue = this.beforeChangeHook(newValue);
    this.value = newValue;

    if (!this.isValuesDiffer(oldValue, newValue))
      return;

    this.dependenciesSlot.broadcast(this);

    if (Cell.recalcCount == 0) {
      // if everything is stable, notify watchers now
      notifyWatchers.call(this, newValue);
    } else {
      // if there are pending slot recomputations -- delay
      if (!this.delayedBroadcast)
        this.delayedBroadcast = notifyWatchers;
      this._markForCompletion();
    }

    function notifyWatchers(newValue) {
      if (newValue === undefined) {
        if (oldValue !== undefined)
          this.undefinedSlot.broadcast(this);
        return;
      }

      if (!this.equality(oldValue, newValue))
        this.changedSlot.broadcast(this);
    }
  },
  // 'returns' value in continuation-passing style way. Calls body
  // with cell's value. If value is undefined, calls body when value
  // becomes defined. Returns undefined
  getValue: function (body) {
    if (this.value)
      body(this.value);
    else
      this.changedSlot.subscribeOnce(function (self) {
        body(self.value);
      });
  },
  // continuus getValue. Will call cb now and every time the value changes,
  // passing it to cb.
  subscribeValue: function (cb) {
    var cell = this;
    var slave = this.subscribeAny(function () {
      cb(cell.value);
    });
    cb(cell.value);

    return {
      cancel: function () {
        cell.undefinedSlot.unsubscribe(slave);
        cell.changedSlot.unsubscribe(slave);
      }
    }
  },
  // schedules cell value recalculation
  recalculate: function () {
    if (this.queuedValueUpdate)
      return;
    this.resetRecalculateAt();
    Cell.recalcCount++;
    Cell.planUpdate(this);
    this.queuedValueUpdate = true;
  },
  // forces cell recalculation unless async set is in progress
  // recalculate() call would abort and re-issue in-flight XHR
  // request, which is almost always bad thing.
  //
  // If in-progress future is marked as weak then we force
  // recalculation. Weak futures can be handy in same cases, in
  // particular during network error recovery, where invalidate() call
  // should force new network request.
  invalidate: function (callback) {
    if (callback)
      this.changedSlot.subscribeOnce(callback);
    if (this.pendingFuture && !this.pendingFuture.weak)
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
    try {
      var context = this.mkFormulaContext();
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
      return false;

    this.pendingFuture = null;

    if (future.valueTransformer && !(value instanceof Future))
      value = (future.valueTransformer)(value);

    this.setValue(value);
    return true;
  },
  cancelAsyncSet: function () {
    var async = this.pendingFuture;
    if (!async)
      return;
    this.pendingFuture = null;
    async.cancelled = true;
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
    if (time instanceof Date)
      time = time.valueOf();

    if (this.recalculateAtTime) {
      if (this.recalculateAtTime < time)
        return;
      clearTimeout(this.recalculateAtTimeout);
      this.recalculateAtTimeout = undefined;
    }
    this.recalculateAtTime = time;

    var delay = time - (new Date()).valueOf();

    if (delay <= 0)
      this.invalidate();
    else
      // yes we re-check current time after delay
      // as I've seen few cases where browsers run callback earlier by few milliseconds
      this.recalculateAtTimeout = setTimeout(_.bind(this.recalculateAt, this, time), delay);
  },
  recalculateAfterDelay: function (delayMillis) {
    var time = (new Date()).valueOf();
    time += delayMillis;
    this.recalculateAt(time);
  },
  // modifies some (potentially nested) attribute of value
  // makes sure that old version of value doesn't notice the change
  setValueAttr: function (attrValue, firstAttribute/*, restNestedAttributes... */) {
    var currentValue = _.clone(this.value);
    var topValue = currentValue;
    var i;
    for (i = 1; i < arguments.length - 1; i++) {
      var nextValue = _.clone(currentValue[arguments[i]]);
      currentValue[arguments[i]] = nextValue;
      currentValue = nextValue;
    }
    currentValue[arguments[arguments.length-1]] = attrValue;
    this.setValue(topValue);
  },
  // detaches this cell from it's sources making it garbage
  // collectable. If JS would have weak-pointers we could get away
  // without explicit detaching, but it doesn't yet.
  detach: function () {
    var recalculate = this.boundRecalculate;
    _.each(this.sources, function (cell) {
      cell.dependenciesSlot.unsubscribeCallback(recalculate);
    });
    clearTimeout(this.recalculateAtTimeout);
    this.recalculateAtTimeout = undefined;
  }
});

_.extend(Cell, {
  EMPTY_OBJECT: {},
  updatedCells: [],
  recalcGeneration: {},
  recalcCount: 0,
  pendingUpdates: [],
  forgetState: function () {
    Cell.updatedCells = [];
    Cell.pendingUpdates = [];
    Cell.recalcGeneration = {};
    Cell.recalcCount = 0;
  },
  planUpdate: function (cell) {
    var pendingUpdates = Cell.pendingUpdates;
    pendingUpdates.push(cell);
    if (pendingUpdates.length === 1) {
      setTimeout(Cell.invokeUpdates, 0);
    }
  },
  invokeUpdates: function () {
    var limit = 32;
    var pendingUpdates = Cell.pendingUpdates;
    while (pendingUpdates.length && limit--) {
      var cell = pendingUpdates.shift();
      cell.tryUpdatingValue();
    }
    if (pendingUpdates.length) {
      setTimeout(Cell.invokeUpdates, 0);
    }
  },
  // this thing is called when there are no pending cell
  // recomputations. We use delay future value computations (XHR gets,
  // for example) and observers update till such 'quiescent'
  // state. Otherwise it's possible to initiate XHR GET only to abort
  // it few milliseconds later due to new dependency value
  completeGeneration: function () {
    var updatedCells = this.updatedCells;
    this.updatedCells = [];
    this.recalcGeneration = {};
    var i, len = updatedCells.length;
    for (i = 0; i < len; i++) {
      Cell.completeCellDelay(updatedCells[i]);
    }
  },
  completeCellDelay: function (cell) {
    var future = cell.pendingFuture;
    if (future && !future.started) {
      try {
        future.start(cell);
      } catch (e) {
        console.log("Got error trying to start future: ", e);
      }
    }
    if (cell.delayedBroadcast) {
      cell.delayedBroadcast.call(cell, cell.value);
      cell.delayedBroadcast = null
    }
  }
})
