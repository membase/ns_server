
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
