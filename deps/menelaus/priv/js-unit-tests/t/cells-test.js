
var CellsTest = TestCase("CellsTest");

CellsTest.prototype.setUp = function () {
  this.clockDestructor = Clock.hijack();
}

CellsTest.prototype.tearDown = function () {
  Clock.tickFarAway();
  this.clockDestructor();
  Cell.forgetState();
}

CellsTest.prototype.testSetup = function () {
  assert(!!this.clockDestructor);
}

CellsTest.prototype.testCallbacks = function () {
  var cell = new Cell();

  var anyFirings = 0;
  var definedFirings = 0;
  var undefinedFirings = 0;

  var assertIncreases = mkAssertIncreases(function () {
    return {anyFirings: anyFirings,
            definedFirings: definedFirings,
            undefinedFirings: undefinedFirings};
  });

  cell.subscribe(function () {
    definedFirings++;
  });

  cell.subscribeAny(function () {
    anyFirings++;
  });

  cell.subscribe(function () {
    undefinedFirings++;
  }, {
    'undefined': true,
    'changed': false
  });

  assertIncreases(["definedFirings", "anyFirings"],
                  function () {
                    cell.setValue(2);
                  });

  assertIncreases(["undefinedFirings", "anyFirings"],
                  function () {
                    cell.setValue(undefined);
                  });

  assertIncreases(["definedFirings", "anyFirings"],
                  function () {
                    cell.setValue(3);
                  });

  var deliverValue;

  assertIncreases(["undefinedFirings", "anyFirings"], function () {
    cell.setValue(future(function (_deliverValue) {
      deliverValue = _deliverValue;
    }))
  });

  assertEventuallyBecomes(function () {
    return !!deliverValue;
  });

  assertIncreases(["definedFirings", "anyFirings"],
                  function () {
                    deliverValue(4);
                  });

  assertEquals(4, cell.value);
}

CellsTest.prototype.checkFormulaWithFutureCase = function (sources) {
  var cell = new Cell(function () {
    if (realFormula)
      return realFormula();
  }, sources);

  var deliverValue;
  var realFormula = function () {
    return future(function (_deliverValue) {
      deliverValue = _deliverValue;
    });
  }

  assertSame(undefined, cell.value);

  cell.recalculate();

  assertEventuallyBecomes(function () {
    return !!deliverValue
  });

  assertSame(undefined, cell.value);

  deliverValue(3);

  assertEventuallyBecomes(function () {
    return cell.value == 3;
  });

  realFormula = function () {
    return 5;
  }

  cell.recalculate();

  assertEventuallyBecomes(function () {
    return cell.value == 5;
  });
}

CellsTest.prototype.testFormulaWithFuture = function () {
  this.checkFormulaWithFutureCase();
}

CellsTest.prototype.testFormulaWithFutureWithSources = function () {
  this.checkFormulaWithFutureCase({});
}

CellsTest.prototype.testFormulaCells = function () {
  var aCell = new Cell();
  var bCell = new Cell();
  var cCell = new Cell(function (a,b) {
    assertEquals(this.a, a);
    assertEquals(this.b, b);

    var context = this.self.context;
    assertEquals(context.a, aCell);
    assertEquals(aCell.value, a);
    assertEquals(context.b, bCell);
    assertEquals(bCell.value, b);

    return (a + b) % 3;
  }, {a:aCell,b:bCell});

  assertSame(undefined, cCell.value);

  var cUpdates = 0;

  cCell.subscribeAny(function () {cUpdates++});

  var assertIncreases = mkAssertIncreases(function () {
    return {cUpdates: cUpdates};
  });

  assertIncreases([], function () {
    aCell.setValue(1);
  });
  assertSame(undefined, cCell.value);

  assertIncreases("cUpdates", function () {
    bCell.setValue(0);
  });

  assertEquals(1, cCell.value);

  assertIncreases([], function () {
    bCell.setValue(3);
  });
  assertEquals(1, cCell.value);

  assertIncreases("cUpdates", function () {
    bCell.setValue(undefined);
    aCell.setValue(undefined);
  });

  assertSame(undefined, cCell.value);
}

// verifies that we don't overflow anything with long formula
// dependency chains and that we fire callbacks and initiate futures
// when everything is quiet
CellsTest.prototype.testLongChainsAndQuiscentState = function () {
  var cells = [new Cell()];
  _.each(_.range(1000), function (i) {
    cells.push(new Cell(function (dep) {
      if (i == cells.length/2)
        Clock.tickFarAway();
      return dep+1;
    }, {dep: cells[i]}))
  });

  var events = [];

  cells.push(new Cell(function (dep) {
    events.push("last-cell-calculated");
    return dep+1;
  }, {dep: cells[cells.length-1]}));

  cells[0].subscribeAny(function () {
    events.push("initial-cell-callback-fired");
  });

  var futureCell = new Cell(function (dep) {
    return future(function () {
      events.push("future-cell-async-started");
    });
  }, {dep: cells[cells.length/2]});

  cells[0].setValue(0);

  for (var i = cells.length*20; i >= 0; i--) {
    if (cells[cells.length-1].value !== undefined)
      break;
    Clock.tick(20);
  }

  assertEquals(cells.length-1, cells[cells.length-1].value);

  assertEventuallyBecomes(function () {
    return events.length == 3;
  }, function (raiser) {
    console.log("events:", events);
    raiser();
  });

  assertEquals("last-cell-calculated", events[0]);
  assertSetEquals(["future-cell-async-started", "initial-cell-callback-fired"],
                  events.slice(1));
}

CellsTest.prototype.testErrorDetection = function () {
  var cell = new Cell();
  var f = function () {};
  assertException(function () {
    new Cell(f, {c: cell, a: null});
  });
  assertException("non-cell source must be detected", function () {
    new Cell(f, {c: cell, a: 1});
  });
  var okCell;
  assertNoException(function () {
    okCell = new Cell(f, {c: cell});
  });

  assertException(function () {
    (new Cell()).setSources({c: cell});
  });
  assertException("sources cannot be updated yet", function () {
    okCell.setSources({a: new Cell()});
  });

  assertException("unknown sources in args must be detected", function () {
    new Cell(function (a,b) {
    }, {a: new Cell()});
  });
  assertNoException(function () {
    new Cell(function (a) {
    }, {a: new Cell()});
  });

  Clock.tickFarAway();
}

CellsTest.prototype.testSimpleFormulaCell = function () {
  var events = [];
  var cell = new Cell(function () {
    events.push(3);
    return 3;
  });

  Clock.tickFarAway();

  assertEquals([3], events)
  assertEquals(3, cell.value);
}

CellsTest.prototype.testInvalidate = function () {
  var events = [];
  var deliverValue;

  var cell = new Cell(function () {
    events.push("recalc");
    return future(function (_deliverValue) {
      deliverValue = _deliverValue;
    });
  });

  assertEventuallyBecomes(function () {
    return events.length == 1;
  });

  assertEventuallyBecomes(function () {
    return deliverValue != null;
  });

  assertEquals(["recalc"], events);

  cell.invalidate();
  Clock.tickFarAway();
  assertEquals("no pending future recalculation after invalidate",
               ["recalc"], events);

  deliverValue(1);
  Clock.tickFarAway();
  assertEquals(1, cell.value);

  assertEquals(["recalc"], events);
  cell.invalidate();
  Clock.tickFarAway();
  assertEquals("invalidate causes recalculation",
               ["recalc", "recalc"], events);
}
