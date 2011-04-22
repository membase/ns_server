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
$.fn.observePotentialChanges = (function () {
  var intervalId;
  var period = 20;
  var maxIdlePeriods = 4;

  var hadActivity;
  var idlePeriods;

  var idGen = 0;
  var callbacks = {};
  var callbacksSize = 0;

  function timerCallback() {
    for (var i in callbacks) {
      (callbacks[i])();
    }

    if (!hadActivity) {
      if (++idlePeriods >= maxIdlePeriods) {
        suspendTimer();
        idlePeriods = 0;
      }
    } else {
      idlePeriods = 0;
      hadActivity = undefined;
    }
  }
  function activateTimer() {
    hadActivity = true;
    if (intervalId != null)
      return;
    intervalId = setInterval(timerCallback, period);
  }
  function suspendTimer() {
    if (intervalId == null)
      return;
    clearInterval(intervalId);
    intervalId = null;
  }
  function requestTimer(callback) {
    callbacks[++idGen] = callback;
    callbacksSize++;

    activateTimer();
    return idGen;
  }
  function releaseTimer(id) {
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

    function cb() {
      callback.call(null, instance);
      if (!boundF)
        bindEvents();
    }

    id = requestTimer(cb);

    function bindEvents() {
      query.bind(events, boundF = function (e) {
        activateTimer();
        unbindEvents();
      });
    }

    function unbindEvents() {
      query.unbind(events, boundF);
      boundF = null;
    }

    bindEvents();
    return instance;
  }
})();

$.fn.observeInput = function (callback) {
  var query = this;
  var prevObject = query.prevObject || $('html > body');
  var lastValue = query.val();

  return prevObject.observePotentialChanges(function (instance) {
    var newValue = query.val();
    if (newValue == lastValue)
      return;

    lastValue = newValue;
    callback.call(query, lastValue, instance);
  });
}
