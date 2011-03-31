
function assertEventuallyBecomes(predicate, raiser) {
  var intervals = [10, 30, 50, 100, 200, 500, 1000, 3000, 8000];

  function defaultRaiser() {
    fail("assertEventuallyBecomes failed");
  }

  function badCase() {
    if (!raiser)
      defaultRaiser();
    else
      raiser(defaultRaiser);
    throw new Error("should not reach");
  }

  ;(function () {
    if (predicate())
      return;

    var stopped = Clock.tickFarAway(predicate);

    if (stopped)
      return;

    badCase();
  })();

  Clock.tickFarAway();

  if (!predicate()) {
    console.log("predicate eventually fails");
    badCase();
  }
}

function mkAssertIncreases(firingsCounts) {
  function assertIncreases(counterNames, body, by) {
    by = by || 1;
    if (!_.isArray(counterNames))
      counterNames = [counterNames];

    var oldCounts = firingsCounts();
    body();

    function raiser() {
      console.log("oldCounts: ", oldCounts);
      console.log("newCounts: ", firingsCounts());
      fail("assertIncreases failed for names: " + counterNames.join(', '));
    }

    assertEventuallyBecomes(function () {
      var newCounts = firingsCounts();
      return _.all(counterNames, function (name) {
        var expected = oldCounts[name] + by;
        var actual = newCounts[name];
        assert("expected counts for name:" + name, actual <= expected);
        return actual == expected;
      });
    }, raiser);

    var restKeys = _.reject(_.keys(oldCounts), function (name) {
      return _.include(counterNames, name);
    });

    var newCounts = firingsCounts();
    _.each(restKeys, function (name) {
      assertEquals("rest keys for name:" + name, oldCounts[name], newCounts[name]);
    });
  }

  return assertIncreases;
}

function assertInclusion(msg, item, set) {
  assertTrue(String(msg) + " inclusion", _.include(set, item));
}

function assertSetEquals(set1, set2) {
  set1 = _.toArray(set1);
  set2 = _.toArray(set2);
  assertEquals("set{1,2}.length", set1.length, set2.length); 
  var missing = [];
  _.each(set1, function (e, i) {
    if (!_.include(set2, e))
      missing.push(i);
  });
  if (missing.length) {
    fail("missing set1 elements: " + missing.join(", "));
  }
}
