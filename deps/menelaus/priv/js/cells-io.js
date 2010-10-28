future.get = function (ajaxOptions, valueTransformer, nowValue, futureWrapper) {
  // var aborted = false;
  var options = {
    valueTransformer: valueTransformer,
    cancel: function () {
      // aborted = true;
      operation.cancel();
    },
    nowValue: nowValue
  }
  var operation;
  if (ajaxOptions.url === undefined)
    throw new Error("url is undefined");

  function initiateXHR(dataCallback) {
    var opts = {dataType: 'json',
                success: dataCallback};
    // if (ajaxOptions.ignoreErrors) {
    //   opts.error = function () {
    //     if (aborted)
    //       return;
    //     setTimeout(function () {
    //       if (aborted)
    //         return;
    //       initiateXHR(dataCallback);
    //     }, 5000);
    //   }
    // }
    operation = IOCenter.performGet(_.extend(opts, ajaxOptions));
  }
  return (futureWrapper || future)(initiateXHR, options);
}

future.pollingGET = function (ajaxOptions, valueTransformer, nowValue, futureWrapper) {
  var initiator = futureWrapper || future;
  var interval = 2000;
  if (ajaxOptions.interval) {
    interval = ajaxOptions.interval;
    delete ajaxOptions.interval;
  }
  return future.get(ajaxOptions, valueTransformer, nowValue, function (body, options) {
    return initiator(function (dataCallback) {
      var context = this;
      function dataCallbackWrapper(data) {
        if (!dataCallback.continuing(data))
          return;
        setTimeout(function () {
          if (dataCallback.continuing(data))
            body.call(context, dataCallbackWrapper);
        }, interval);
      }
      body.call(context, dataCallbackWrapper);
    }, options);
  });
}

future.infinite = function () {
  var rv = future(function () {
    rv.active = true;
    rv.cancel = function () {
      rv.active = false;
    }
  });
  return rv;
}

future.getPush = function (ajaxOptions, valueTransformer, nowValue, waitChange) {
  var options = {
    valueTransformer: valueTransformer,
    cancel: function () {
      operation.cancel();
    },
    nowValue: nowValue
  }
  var operation;
  var etag;
  var recovingFromError;

  if (!waitChange)
    waitChange = 20000;

  if (ajaxOptions.url == undefined)
    throw new Error("url is undefined");

  function sendRequest(dataCallback) {
    var options = _.extend({dataType: 'json',
                            success: gotData},
                           ajaxOptions);

    if (options.url.indexOf("?") < 0)
      options.url += '?waitChange='
    else
      options.url += '&waitChange='
    options.url += waitChange;

    var originalUrl = options.url;
    if (etag) {
      options.url += "&etag=" + encodeURIComponent(etag)
      options.timeout = 30000;
    }
    options.prepareReGet = function (opt) {
      // make us weak so that cell invalidations will force new
      // network request
      dataCallback.async.weak = true;

      // recovering from error will 'undo' etag asking immediate
      // response, which we need in this case
      opt.url = originalUrl;
      return opt;
    }

    operation = IOCenter.performGet(options);

    function gotData(data) {
      dataCallback.async.weak = false;

      etag = data.etag;
      // pass our data to cell
      if (dataCallback.continuing(data))
        // and submit new request if we are not cancelled
        _.defer(_.bind(sendRequest, null, dataCallback));
    }
  }

  return future(sendRequest, options);
}

// this guy holds queue of failed actions and tries to repeat one of
// them every 5 seconds. Once it succeeds it changes status to healthy
// and repeats other actions
var ErrorQueue = mkClass({
  initialize: function () {
    var self = this;

    self.status = new Cell();
    self.status.setValue({
      healthy: true,
      repeating: false
    });
    self.repeatTimeout = null;
    self.queue = [];
    self.status.subscribeValue(function (s) {
      if (s.healthy)
        self.repeatInterval = undefined;
    });
  },
  repeatIntervalBase: 10000,
  repeatInterval: undefined,
  planRepeat: function () {
    var interval = this.repeatInterval;
    if (interval == null)
      return this.repeatIntervalBase;
    return Math.min(interval * 2, 300000);
  },
  submit: function (action) {
    this.queue.push(action);
    this.status.setValueAttr(false, 'healthy');
    if (this.repeatTimeout || this.status.value.repeating)
      return;

    var interval = this.repeatInterval = this.planRepeat();
    var at = (new Date()).getTime() + interval;
    this.status.setValueAttr(at, 'repeatAt');
    this.repeatTimeout = setTimeout($m(this, 'onTimeout'),
                                    interval);
  },
  forceAction: function (forcedAction) {
    var self = this;

    if (self.repeatTimeout) {
      clearTimeout(self.repeatTimeout);
      self.repeatTimeout = null;
    }

    if (!forcedAction) {
      if (!self.queue.length) {
        self.status.setValueAttr(true, 'healthy');
        return;
      }
      forcedAction = self.queue.pop();
    }

    self.status.setValueAttr(true, 'repeating');

    forcedAction(function (isOk) {
      self.status.setValueAttr(false, 'repeating');

      if (isOk == false)
        return self.submit(forcedAction);

      // if result is undefined or true, we issue next action
      if (isOk)
        self.status.setValueAttr(true, 'healthy');
      self.onTimeout();
    });
  },
  cancel: function (action) {
    this.queue = _.without(this.queue, action);
    if (this.queue.length || this.status.value.repeating)
      return;

    this.healthy.setValue(true);
    if (this.repeatTimeout) {
      cancelTimeout(this.repeatTimeout);
      this.repeatTimeout = null;
    }
  },
  onTimeout: function () {
    this.repeatTimeout = null;
    this.forceAction();
  }
});

// this is central place that defines policy of XHR error handling,
// all cells reads (there are no cells writes by definition) are
// tracked and controlled by this guy
var IOCenter = (function () {
  var status = new Cell();
  status.setValue({
    inFlightCount: 0
  });

  var errorQueue = new ErrorQueue();
  errorQueue.status.subscribeValue(function (v) {
    status.setValue(_.extend({}, status.value, v));
  });

  // S is short for self
  var S;
  return S = {
    status: status,
    forceRepeat: function () {
      errorQueue.forceAction();
    },
    performGet: function (options) {
      var usedOptions = _.clone(options);

      usedOptions.error = gotResponse;
      usedOptions.success = gotResponse;

      var op = {
        cancel: function () {
          if (op.xhr)
            return Abortarium.abortRequest(op.xhr);

          if (op.done)
            return;

          // we're not done yet and we're not in-flight, so we must
          // be on error queue
          errorQueue.cancel(sendXHR);
        }
      }

      var extraCallback;

      // this is our function to send _and_ re-send
      // request. extraCallback parameter is used during re-sends to
      // execute some code when request is complete
      function sendXHR(_extraCallback) {
        extraCallback = _extraCallback;

        status.setValueAttr(status.value.inFlightCount + 1, 'inFlightCount');

        op.xhr = $.ajax(usedOptions);
      }
      sendXHR(function (isOk) {
        if (isOk != false)
          return;

        // our first time 'continuation' is if we've got error then we
        // submit us to repeat queue and maybe update options
        if (options.prepareReGet)
          usedOptions = options.prepareReGet(usedOptions)
        errorQueue.submit(sendXHR);
      });
      return op;

      function gotResponse(data, xhrStatus) {
        op.xhr = null;
        status.setValueAttr(status.value.inFlightCount - 1, 'inFlightCount');

        if (xhrStatus == 'success') {
          op.done = true;
          extraCallback(true);
          return options.success.apply(this, arguments);
        }

        var isOk = (function (xhr) {
          if (Abortarium.isAborted(xhr))
            return;
          if (S.isNotFound(xhr)) {
            options.success.call(this,
                                 options.missingValue || undefined,
                                 'notfound');
            return;
          }

          // if our caller has it's own error handling strategy let him do it
          if (options.error) {
            options.error.apply(this, arguments);
            return;
          }

          return false;
        })(data);

        if (isOk != false)
          op.done = true;

        extraCallback(isOk);
      }
    },
    readStatus: function (xhr) {
      var status = 0;
      try {
        status = xhr.status
      } catch (e) {
        if (!xhr)
          throw e;
      }
      return status;
    },
    // we treat everything with 4xx status as not found because for
    // GET requests that we send, we don't have ways to re-send them
    // back in case of 4xx response comes.
    //
    // For example, we cannot do anything with sudden (and unexpected
    // anyway) "401-Authenticate" response, so we just interpret is as
    // if no resource exists.
    isNotFound: function (xhr) {
      var status = S.readStatus(xhr);
      return (400 <= status && status < 500);
    }
  };
})();

;(function () {
  new Cell(function (status) {
    return status.healthy;
  }, {
    status: IOCenter.status
  }).subscribeValue(function (healthy) {
    console.log("IOCenter.status.healthy: ", healthy);
  });
})();
