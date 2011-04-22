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
Cell.prototype.propagateMeta = function () {
  var metaCell = this.ensureMetaCell();
  var staleMetaCell;
  var sourceCells = this.getSourceCells();

  if (metaCell.cancelRefresh) {
    metaCell.cancelRefresh();
  }

  for (var i = sourceCells.length - 1; i >= 0; i--) {
    var cell = sourceCells[i].metaCell;
    if (!cell || !cell.value) {
      continue;
    }
    var metaValue = cell.value;
    if (metaValue.stale) {
      staleMetaCell = cell;
      break;
    }
  }

  metaCell.setValueAttr(!!staleMetaCell, 'stale');

  var refreshSlave = new Slave($m(this, 'propagateMeta'));

  if (staleMetaCell) {
    staleMetaCell.changedSlot.subscribeWithSlave(refreshSlave);
  } else {
    for (var j = sourceCells.length - 1; j >= 0; j--) {
      var cell = sourceCells[j].metaCell;
      if (!cell) {
        continue;
      }
      cell.changedSlot.subscribeWithSlave(refreshSlave);
    }
  }

  metaCell.cancelRefresh = function () {
    refreshSlave.die();
    for (var i = sourceCells.length - 1; i >= 0; i--) {
      var cell = sourceCells[i].metaCell;
      if (!cell) {
        continue;
      }
      cell.changedSlot.cleanup();
    }
  };
};

Cell.STANDARD_ERROR_MARK = {"this is error marker":true};

Cell.cacheResponse = function (cell) {
  var cachingCell = new Cell(function () {
    var newValue = cell.value;
    var self = this.self;
    var oldValue = self.value;
    if (newValue === undefined) {
      if (oldValue === undefined) {
        return oldValue;
      }
      newValue = oldValue;
      self.setMetaAttr('loading', true);
      return newValue;
    }
    self.setMetaAttr('loading', false);
    if (newValue === Cell.STANDARD_ERROR_MARK) {
      newValue = oldValue;
      self.setMetaAttr('stale', true);
    } else {
      self.setMetaAttr('stale', false);
    }
    return newValue;
  }, {
    src: cell
  });

  cachingCell.target = cell;
  cachingCell.ensureMetaCell();
  cachingCell.propagateMeta = null;

  cachingCell.delegateInvalidationMethods(cell);

  return cachingCell;
};

Cell.prototype.delegateInvalidationMethods = function (target) {
  var self = this;
  _.each(("recalculate recalculateAt recalculateAfterDelay invalidate").split(' '), function (methodName) {
    self[methodName] = $m(target, methodName);
  });
};

Cell.mkCaching = function (formula, sources) {
  var cell = new Cell(formula, sources);
  return Cell.cacheResponse(cell);
};

future.get = function (ajaxOptions, valueTransformer, nowValue, futureWrapper) {
  // var aborted = false;
  var options = {
    valueTransformer: valueTransformer,
    cancel: function () {
      // aborted = true;
      operation.cancel();
    },
    nowValue: nowValue
  };
  var operation;
  if (ajaxOptions.url === undefined) {
    throw new Error("url is undefined");
  }

  function initiateXHR(dataCallback) {
    var opts = {dataType: 'json',
                prepareReGet: function (opts) {
                  if (opts.errorMarker) {
                    // if we have error marker pass it to data
                    // callback now to mark error
                    if (!dataCallback.continuing(opts.errorMarker)) {
                      // if we were cancelled, cancel IOCenter
                      // operation
                      operation.cancel();
                    }
                  }
                },
                success: dataCallback};
    if (ajaxOptions.onError) {
      opts.error = function () {
        ajaxOptions.onError.apply(this, [dataCallback].concat(_.toArray(arguments)));
      };
    }
    operation = IOCenter.performGet(_.extend(opts, ajaxOptions));
  }
  return (futureWrapper || future)(initiateXHR, options);
};

future.withEarlyTransformer = function (earlyTransformer) {
  return {
    // we return a function
    get: function (ajaxOptions, valueTransformer, newValue, futureWrapper) {
      // that will delegate to future.get, but...
      return future.get(ajaxOptions, valueTransformer, newValue, futureReplacement);
      // will pass our function instead of future
      function futureReplacement(initXHR) {
        // that function will delegate to real future
        return (future || futureWrapper)(function (dataCallback) {
          // and once future is started
          // will call original future start function replacing dataCallback
          dataCallbackReplacement.cell = dataCallback.cell;
          dataCallbackReplacement.async = dataCallback.async;
          dataCallbackReplacement.continuing = dataCallback.continuing;
          initXHR(dataCallbackReplacement);
          function dataCallbackReplacement(value, status, xhr) {
            // replaced dataCallback will invoke earlyTransformer
            earlyTransformer(value, status, xhr);
            // and will finally pass data to real dataCallback
            dataCallback(value);
          }
        });
      }
    }
  };
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
        if (!dataCallback.continuing(data)) {
          return;
        }
        setTimeout(function () {
          if (dataCallback.continuing(data)) {
            body.call(context, dataCallbackWrapper);
          }
        }, interval);
      }
      body.call(context, dataCallbackWrapper);
    }, options);
  });
};

future.infinite = function () {
  var rv = future(function () {
    rv.active = true;
    rv.cancel = function () {
      rv.active = false;
    };
  });
  return rv;
};

future.getPush = function (ajaxOptions, valueTransformer, nowValue, waitChange) {
  var options = {
    valueTransformer: valueTransformer,
    cancel: function () {
      operation.cancel();
    },
    nowValue: nowValue
  };
  var operation;
  var etag;

  if (!waitChange) {
    waitChange = 20000;
  }

  if (ajaxOptions.url === undefined) {
    throw new Error("url is undefined");
  }

  function sendRequest(dataCallback) {

    function gotData(data) {
      dataCallback.async.weak = false;

      etag = data.etag;
      // pass our data to cell
      if (dataCallback.continuing(data)) {
        // and submit new request if we are not cancelled
        _.defer(_.bind(sendRequest, null, dataCallback));
      }
    }

    var options = _.extend({dataType: 'json',
                            success: gotData},
                           ajaxOptions);

    if (options.url.indexOf("?") < 0) {
      options.url += '?waitChange=';
    } else {
      options.url += '&waitChange=';
    }
    options.url += waitChange;

    var originalUrl = options.url;
    if (etag) {
      options.url += "&etag=" + encodeURIComponent(etag);
      options.pushRequest = true;
      options.timeout = 30000;
    }
    options.prepareReGet = function (opt) {
      if (opt.errorMarker) {
        // if we have error marker pass it to data callback now to
        // mark error
        if (!dataCallback.continuing(opt.errorMarker)) {
          // if we were cancelled, cancel IOCenter operation
          operation.cancel();
          return;
        }
      }
      // make us weak so that cell invalidations will force new
      // network request
      dataCallback.async.weak = true;

      // recovering from error will 'undo' etag asking immediate
      // response, which we need in this case
      opt.url = originalUrl;
      return opt;
    };

    operation = IOCenter.performGet(options);
  }

  return future(sendRequest, options);
};

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
      if (s.healthy) {
        self.repeatInterval = undefined;
      }
    });
  },
  repeatIntervalBase: 5000,
  repeatInterval: undefined,
  planRepeat: function () {
    var interval = this.repeatInterval;
    if (interval == null) {
      return this.repeatIntervalBase;
    }
    return Math.min(interval * 1.618, 300000);
  },
  submit: function (action) {
    this.queue.push(action);
    this.status.setValueAttr(false, 'healthy');
    if (this.repeatTimeout || this.status.value.repeating) {
      return;
    }

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

      if (isOk == false) {
        return self.submit(forcedAction);
      }

      // if result is undefined or true, we issue next action
      if (isOk) {
        self.status.setValueAttr(true, 'healthy');
      }
      self.onTimeout();
    });
  },
  cancel: function (action) {
    this.queue = _.without(this.queue, action);
    if (this.queue.length || this.status.value.repeating) {
      return;
    }

    this.status.setValueAttr(true, 'healthy');
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
  var S = {
    status: status,
    forceRepeat: function () {
      errorQueue.forceAction();
    },
    performGet: function (options) {
      var usedOptions = _.clone(options);

      if (usedOptions.stdErrorMarker) {
        usedOptions.errorMarker = Cell.STANDARD_ERROR_MARK;
      }

      usedOptions.error = gotResponse;
      usedOptions.success = gotResponse;

      var op = {
        cancel: function () {
          if (op.xhr) {
            return Abortarium.abortRequest(op.xhr);
          }

          if (op.done) {
            return;
          }

          op.cancelled = true;

          // we're not done yet and we're not in-flight, so we must
          // be on error queue
          errorQueue.cancel(sendXHR);
        }
      };

      var extraCallback;

      // this is our function to send _and_ re-send
      // request. extraCallback parameter is used during re-sends to
      // execute some code when request is complete
      function sendXHR(_extraCallback) {
        extraCallback = _extraCallback;

        status.setValueAttr(status.value.inFlightCount + 1, 'inFlightCount');

        if (S.simulateDisconnect) {
          setTimeout(function () {
            usedOptions.error.call(usedOptions, {status: 500}, 'error');
          }, 200);
          return;
        }
        op.xhr = $.ajax(usedOptions);
      }
      sendXHR(function (isOk) {
        if (isOk != false) {
          return;
        }

        // our first time 'continuation' is if we've got error then we
        // submit us to repeat queue and maybe update options
        if (options.prepareReGet) {
          var newOptions = options.prepareReGet(usedOptions);
          if (newOptions != null)
            usedOptions = newOptions;
        }

        if (!op.cancelled) {
          errorQueue.submit(sendXHR);
        }
      });
      return op;

      function gotResponse(data, xhrStatus) {
        op.xhr = null;
        status.setValueAttr(status.value.inFlightCount - 1, 'inFlightCount');
        var args = arguments;
        var context = this;

        if (xhrStatus == 'success') {
          op.done = true;
          extraCallback(true);
          return options.success.apply(this, arguments);
        }

        var isOk = (function (xhr) {
          if (Abortarium.isAborted(xhr)) {
            return;
          }
          if (S.isNotFound(xhr)) {
            options.success.call(this,
                                 options.missingValue || undefined,
                                 'notfound');
            return;
          }

          // if our caller has it's own error handling strategy let him do it
          if (options.error) {
            options.error.apply(context, args);
            return;
          }

          return false;
        })(data);

        if (isOk != false) {
          op.done = true;
        }

        extraCallback(isOk);
      }
    },
    readStatus: function (xhr) {
      var status = 0;
      try {
        status = xhr.status
      } catch (e) {
        if (!xhr) {
          throw e;
        }
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
  return S;
})();

(function () {
  new Cell(function (status) {
    return status.healthy;
  }, {
    status: IOCenter.status
  }).subscribeValue(function (healthy) {
    console.log("IOCenter.status.healthy: ", healthy);
  });
})();
