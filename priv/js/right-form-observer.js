$.fn.observePotentialChanges = (function () {
  var intervalId;
  var period = 20;
  var maxIdlePeriods = 4;

  var hadActivity;
  var idlePeriods;

  var idGen = 0;
  var callbacks = {};
  var callbacksSize = 0;

  var timerCallback = function () {
    for (var i in callbacks) {
      (callbacks[i])();
    }

    if (!hadActivity) {
      if (++idlePeriods >= maxIdlePeriods) {
        console.log("right-observer: suspend due to idleness");
        suspendTimer();
        idlePeriods = 0;
      }
    } else {
      idlePeriods = 0;
      hadActivity = undefined;
    }
  }
  var activateTimer = function () {
    hadActivity = true;
    if (intervalId != null)
      return;
    console.log("right-observer: major activate");
    intervalId = setInterval(timerCallback, period);
  }
  var suspendTimer = function () {
    if (intervalId == null)
      return;
    clearInterval(intervalId);
    intervalId = null;
  }
  var requestTimer = function (callback) {
    callbacks[++idGen] = callback;
    callbacksSize++;

    activateTimer();
    return idGen;
  }
  var releaseTimer = function (id) {
    delete callbacks[id];
    if (--callbacksSize == 0)
      suspendTimer();
  }

  return function (callback) {
    var query = this;
    var events = 'change mousemove click dblclick keyup keydown';
    var boundF;
    var id;

    var instance = {
      stopObserving: function () {
        releaseTimer(id);
        unbindEvents();
      }
    }

    var cb = function () {
      callback.call(null, instance);
      if (!boundF)
        bindEvents();
    }

    id = requestTimer(cb);

    var bindEvents = function () {
      query.bind(events, boundF = function (e) {
        activateTimer();
        unbindEvents();
      });
    }

    var unbindEvents = function () {
      query.unbind(events, boundF);
      boundF = null;
    }

    bindEvents();
    return instance;
  }
})();
