Cell.identity = (function () {
  var counter = 1;
  return function (cell) {
    if (cell.__identity)
      return cell.__identity;
    return (cell.__identity = counter++);
  }
})();

Cell.FlexiFormulaCell = mkClass(Cell, {
  initialize: function ($super, flexiFormula) {
    $super();

    var recalculate = $m(this, 'recalculate');

    var currentSources = this.currentSources = {};

    this.effectiveFormula = function () {
      var rvPair = flexiFormula.call(this);
      var newValue = rvPair[0];
      var dependencies = rvPair[1];

      for (var id in currentSources) {
        if (dependencies[id])
          continue;
        var pair = currentSources[id];
        pair[0].dependenciesSlot.unsubscribe(pair[1]);
        delete currentSources[id];
      }

      for (var id in dependencies) {
        if (id in currentSources)
          continue;
        var cell = dependencies[id];
        var slave = cell.dependenciesSlot.subscribeWithSlave(recalculate);
        currentSources[id] = [cell, slave];
      }

      return newValue;
    }

    this.formulaContext = {self: this};
    this.recalculate();
  },
  detach: function () {
    for (var id in this.currentSources) {
      var pair = currentSources[id];
      pair[0].dependenciesSlot.unsubscribe(pair[1]);
    }
    this.effectiveFormula = function () {}
  },
  setSources: function () {
    throw new Error("unsupported!");
  },
  mkFormulaContext: function () {
    return this.formulaContext;
  }
});

Cell.FlexiFormulaCell.noValueMarker = (function () {
  try {
    throw {}
  } catch (e) {
    return e;
  }
})();

Cell.FlexiFormulaCell.makeComputeFormula = function (formula) {
  var dependencies;
  var noValue = Cell.FlexiFormulaCell.noValueMarker;

  function getValue(cell) {
    var id = Cell.identity(cell);
    if (!dependencies[id])
      dependencies[id] = cell;
    return cell.value;
  }

  function need(cell) {
    var v = getValue(cell);
    if (!v)
      throw noValue;
    return v;
  }

  getValue.need = need;

  return function () {
    dependencies = {};
    var newValue;
    try {
      newValue = formula.call(this, getValue);
    } catch (e) {
      if (e === noValue)
        newValue = undefined;
      else
        throw e;
    }
    var deps = dependencies;
    dependencies = null;
    return [newValue, deps];
  }
}

Cell.compute = function (formula, FlexiFormulaCell) {
  FlexiFormulaCell = FlexiFormulaCell || Cell.FlexiFormulaCell
  var f = Cell.FlexiFormulaCell.makeComputeFormula(formula);
  return new FlexiFormulaCell(f);
}
