future.get = function (ajaxOptions, valueTransformer, nowValue, futureWrapper) {
  var aborted = false;
  var options = {
    valueTransformer: valueTransformer,
    cancel: function () {
      aborted = true;
      Abortarium.abortRequest(xhr);
    },
    nowValue: nowValue
  }
  var xhr;
  if (ajaxOptions.url === undefined)
    throw new Error("url is undefined");

  function initiateXHR(dataCallback) {
    var opts = {type: 'GET',
                dataType: 'json',
                success: dataCallback};
    if (ajaxOptions.ignoreErrors) {
      opts.error = function () {
        if (aborted)
          return;
        setTimeout(function () {
          if (aborted)
            return;
          initiateXHR(dataCallback);
        }, 5000);
      }
    }
    xhr = $.ajax(_.extend(opts, ajaxOptions));
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
      Abortarium.abortRequest(xhr);
    },
    nowValue: nowValue
  }
  var xhr;
  var etag;
  var recovingFromError;

  if (!waitChange)
    waitChange = 20000;

  if (ajaxOptions.url == undefined)
    throw new Error("url is undefined");

  function sendRequest(dataCallback) {
    var options = _.extend({type: 'GET',
                            dataType: 'json',
                            error: onError,
                            success: continuation},
                           ajaxOptions);
    if (options.url.indexOf("?") < 0)
      options.url += '?waitChange='
    else
      options.url += '&waitChange='
    options.url += waitChange;
    if (etag && !recovingFromError) {
      options.url += "&etag=" + encodeURIComponent(etag)
      options.timeout = 30000;
    }

    xhr = $.ajax(options);

    function continuation(data) {
      recovingFromError = false;
      dataCallback.async.weak = false;

      etag = data.etag;
      // pass our data to cell
      if (dataCallback.continuing(data))
        // and submit new request if we are not cancelled
        _.defer(_.bind(sendRequest, null, dataCallback));
    }

    function onError(xhr) {
      if (dataCallback.async.cancelled)
        return;

      if (!etag)
        return onUnexpectedXHRError.apply(this, arguments);

      onNoncriticalXHRError.apply(this, arguments);
      recovingFromError = true;

      // make us weak so that cell invalidations will force new
      // network request
      dataCallback.async.weak = true;

      // try to repeat request after 10 seconds
      setTimeout(function () {
        if (dataCallback.async.cancelled)
          return;
        sendRequest(dataCallback);
      }, 10000);
    }
  }

  return future(sendRequest, options);
}
