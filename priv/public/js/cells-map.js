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
// This is new-style computed cells. Those have dynamic set of
// dependencies and have more lightweight, functional style. They are
// also lazy, which means that cell value is not (re)computed if
// nothing demands that value. Which happens when nothing is
// subscribed to this cell and it doesn't have dependent cells.
//
// Main guy here is Cell.compute. See it's comments. See also
// testCompute test in cells-test.js.


Cell.id = (function () {
  var counter = 1;
  return function (cell) {
    if (cell.__identity) {
      return cell.__identity;
    }
    return (cell.__identity = counter++);
  };
})();

FlexiFormulaCell = mkClass(Cell, {
  emptyFormula: function () {},
  initialize: function ($super, flexiFormula, isEager) {
    $super();

    var recalculate = $m(this, 'recalculate'),
        currentSources = this.currentSources = {};

    this.formula = function () {
      var rvPair = flexiFormula.call(this),
          newValue = rvPair[0],
          dependencies = rvPair[1];

      for (var i in currentSources) {
        if (dependencies[i]) {
          continue;
        } else {
          var pair = currentSources[i];
          pair[0].dependenciesSlot.unsubscribe(pair[1]);
          delete currentSources[i];
        }
      }

      for (var j in dependencies) {
        if (j in currentSources) {
          continue;
        } else {
          var cell = dependencies[j],
              slave = cell.dependenciesSlot.subscribeWithSlave(recalculate);

          currentSources[j] = [cell, slave];
        }
      }

      return newValue;
    };

    this.formulaContext = {self: this};
    if (isEager) {
      this.effectiveFormula = this.formula;
      this.recalculate();
    } else {
      this.effectiveFormula = this.emptyFormula;
      this.setupDemandObserving();
    }
  },
  setupDemandObserving: function () {
    var demand = {},
        self = this;
    _.each(
      {
        changed: self.changedSlot,
        'undefined': self.undefinedSlot,
        dependencies: self.dependenciesSlot
      },
      function (slot, name) {
        slot.__demandChanged = function (newDemand) {
          demand[name] = newDemand;
          react();
        };
      }
    );
    function react() {
      var haveDemand = demand.dependencies || demand.changed || demand['undefined'];

      if (!haveDemand) {
        self.detach();
      } else {
        self.attachBack();
      }
    }
  },
  needsRefresh: function (newValue) {
    if (this.value === undefined) {
      return true;
    }
    if (newValue instanceof Future) {
      // we don't want to recalculate values that involve futures
      return false;
    }
    return this.isValuesDiffer(this.value, newValue);
  },
  attachBack: function () {
    if (this.effectiveFormula === this.formula) {
      return;
    }

    this.effectiveFormula = this.formula;

    // This piece of code makes sure that we don't refetch things that
    // are already fetched
    var needRecalculation;
    if (this.hadPendingFuture) {
      // if we had future in progress then we will start it back
      this.hadPendingFuture = false;
      needRecalculation = true;
    } else {
      // NOTE: this has side-effect of updating formula dependencies and
      // subscribing to them back
      var newValue = this.effectiveFormula.call(this.mkFormulaContext());
      needRecalculation = this.needsRefresh(newValue);
    }

    if (needRecalculation) {
      // but in the end we call recalculate to correctly handle
      // everything. Calling it directly might start futures which
      // we don't want. And copying it's code here is even worse.
      //
      // Use of prototype is to avoid issue with overriden
      // recalculate. See Cell#delegateInvalidationMethods. We want
      // exact original recalculate behavior here.
      Cell.prototype.recalculate.call(this);
    }
  },
  detach: function () {
    var currentSources = this.currentSources;
    for (var id in currentSources) {
      if (id) {
        var pair = currentSources[id];
        pair[0].dependenciesSlot.unsubscribe(pair[1]);
        delete currentSources[id];
      }
    }
    if (this.pendingFuture) {
      this.hadPendingFuture = true;
    }
    this.effectiveFormula = this.emptyFormula;
    this.setValue(this.value);  // this cancels any in-progress
                                // futures
    clearTimeout(this.recalculateAtTimeout);
    this.recalculateAtTimeout = undefined;
  },
  setSources: function () {
    throw new Error("unsupported!");
  },
  mkFormulaContext: function () {
    return this.formulaContext;
  },
  getSourceCells: function () {
    var rv = [],
        sources = this.currentSources;
    for (var id in sources) {
      if (id) {
        rv.push(sources[id][0]);
      }
    }
    return rv;
  }
});

FlexiFormulaCell.noValueMarker = (function () {
  try {
    throw {};
  } catch (e) {
    return e;
  }
})();

FlexiFormulaCell.makeComputeFormula = function (formula) {
  var dependencies,
      noValue = FlexiFormulaCell.noValueMarker;

  function getValue(cell) {
    var id = Cell.id(cell);
    if (!dependencies[id]) {
      dependencies[id] = cell;
    }
    return cell.value;
  }

  function need(cell) {
    var v = getValue(cell);
    if (v === undefined) {
      throw noValue;
    }
    return v;
  }

  getValue.need = need;

  return function () {
    dependencies = {};
    var newValue;
    try {
      newValue = formula.call(this, getValue);
    } catch (e) {
      if (e === noValue) {
        newValue = undefined;
      } else {
        throw e;
      }
    }
    var deps = dependencies;
    dependencies = null;
    return [newValue, deps];
  };
};

// Creates cell that is computed by running formula. This function is
// passed V argument. Which is a function that gets values of other
// cells. It is necessary to obtain dependent cell values via that
// function, so that all dependencies are recorded. Then if any of
// (dynamic) dependencies change formula is recomputed. Which may
// produce (apart from new value) new set of dependencies.
//
// V also has a useful helper: V.need which is just as V extracts
// values from cells. But it differs from V in that undefined values
// are never returned. Special exception is raised instead to signal
// that formula value is undefined.
Cell.compute = function (formula) {
  var _FlexiFormulaCell = arguments[1] || FlexiFormulaCell,
      f = FlexiFormulaCell.makeComputeFormula(formula);

  return new _FlexiFormulaCell(f);
};

Cell.computeEager = function (formula) {
  var _FlexiFormulaCell = arguments[1] || FlexiFormulaCell,
      f = FlexiFormulaCell.makeComputeFormula(formula);

  return new _FlexiFormulaCell(f, true);
};

(function () {
  var constructor = function (dependencies) {
    this.dependencies = dependencies;
  }

  function def(delegateMethodName) {
    function delegatedMethod(body) {
      var dependencies = this.dependencies;

      return Cell[delegateMethodName](function (v) {
        var args = [v];
        args.length = dependencies.length+1;
        var i = dependencies.length;
        while (i--) {
          var value = v(dependencies[i]);
          if (value === undefined) {
            return;
          }
          args[i+1] = value;
        }
        return body.apply(this, args);
      });
    }
    constructor.prototype[delegateMethodName] = delegatedMethod;
  }

  def('compute');
  def('computeEager');

  Cell.needing = function () {
    return new constructor(arguments);
  };
})();
