;(function () {
  var global = this;
  var Clock = global.Clock = {};

  Clock.events = new BinaryHeap(function (a, b) {
    return a.at < b.at;
  });

  Clock.now = 0;
  Clock.deadCount = 0;

  Clock.eventsHash = {};
  Clock.lastEventId = 0;

  Clock.reset = function () {
    Clock.events.clear();
    Clock.deadCount = 0;
    Clock.eventsHash = {};
    Clock.now = 0;
    Clock.lastEventId = 0;
  }

  Clock.findClosestEvent = function () {
    if (this.events.isEmpty())
      return;
    return this.events.elements[0];
  }

  Clock.advanceTimeTo = function (epochMillis) {
    while (true) {
      var event = this.findClosestEvent();
      if (!event || event.at > epochMillis) {
        Clock.now = epochMillis;
        return;
      }
      Clock.advanceToNextEvent();
    }
  }

  Clock.tick = function (millis) {
    if (millis == 0)
      return;
    if (millis < 0)
      throw new Error("negative millis passed");
    this.advanceTimeTo(this.now + millis);
  }

  Clock.isAnythingPending = function () {
    return !!this.findClosestEvent();
  }

  Clock.advanceToNextEvent = function () {
    var event = this.findClosestEvent();
    if (!event)
      return;

    var now = Clock.now = event.at;

    do {
      this.deleteEvent(event.id);
      var cb = event.cb;
      cb();
//      console.log("processing event: ", event);
      if (event.recurring) {
        event.at += event.millis;
        this.events.add(event);
        this.eventsHash[event.id] = event;
      }
      event = this.findClosestEvent();
    } while (event && event.at == now);
  }

  Clock.registerEvent = function (cb, millis, recurring) {
    if (millis < 0)
      millis = 0;
    if (!millis && recurring)
      throw new Error("zero interval and recurrence are bad match");
    var id = this.lastEventId++;
    var event = {
      id: id,
      cb: cb,
      at: this.now + millis,
      millis: millis,
      recurring: recurring
    };
//    console.log("registering event: ", event);
    this.events.add(event);
    this.eventsHash[id] = event;
    return id;
  }

  // JDK timers seem to be using same approach with marking events
  // dead and keeping them on heap. But I have seen jdk having very
  // bad 'timer leaks' in some cases. Thus we 'GC' dead events when
  // their count exceeds half of heap size. We still get O(log n)
  // (amortized) deletions, I believe.
  Clock.gc = function () {
    this.events.clear();
    for (var id in this.eventsHash) {
      var event = this.eventsHash[id];
      if (!event.dead)
        this.events.add(event);
    }
    this.deadCount = 0;
  }

  Clock.deleteEvent = function (id) {
    var event = this.eventsHash[id]
    delete this.eventsHash[id];
    if (this.events.elements[0] === event) {
      this.events.popLeast();
      var e;
      while ((e = this.events.elements[0]) && e.dead) {
        this.events.popLeast();
        this.deadCount--;
      }
      return event;
    }
    event.dead = true;
    this.deadCount++;
    if ((this.deadCount << 1) > this.events.getSize())
      this.gc();
    return event;
  }

  Clock.clearEvent = function (id, recurring) {
    var event = this.eventsHash[id];
    if (event == null)
      return;
    if (event.recurring != recurring)
      return;
    this.deleteEvent(id);
  }

  Clock.hijack = function (now) {
    if (now == null) {
      now = global.Date.UTC(2010, 1, 23, 18, 46, 57, 219);
    }

    var NewDate = mkDateWrapper(function (methods, NewDate) {
      var originalInitialize = methods.initialize;

      methods.initialize = function (originalDate, args) {
        if (args.length == 0) {
          return originalInitialize.call(this, originalDate, [Clock.now]);
        }
        return originalInitialize.call(this, originalDate, args);
      }
    });

    OldDate = Date;
    Date = NewDate;

    Clock.reset();
    Clock.now = now;

    return function () {
      Date = OldDate;
      Clock.reset();
    }
  }

  Clock.tickFarAway = function (stopPredicate) {
    var maxNow = this.now + 86400000;
    var i = 0;
    // process either 1000 events or +1 day
    while (i < 1000 && this.now < maxNow) {
      this.advanceToNextEvent();
      // return when stopPredicate is satisfied
      var predicateValue;
      if (stopPredicate && (predicateValue = stopPredicate()))
        return predicateValue;
      if (!stopPredicate && this.events.isEmpty())
        return;
      i++;
    }
  }
}).call(null);

function clearTimeout(id) {
  Clock.clearEvent(id, false);
}

function clearInterval(id) {
  Clock.clearEvent(id, true);
}

function setTimeout(cb, millis) {
  return Clock.registerEvent(cb, millis, false);
}

function setInterval(cb, millis) {
  return Clock.registerEvent(cb, millis, true);
}
