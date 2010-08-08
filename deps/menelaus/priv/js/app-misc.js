function setBoolAttribute(jq, attr, value) {
  if (value) {
    jq.attr(attr, attr);
  } else {
    jq.removeAttr(attr);
  }
}

function normalizeNaN(possNaN) {
  return possNaN << 0;
}

function setFormValues(form, values) {
  form.find('input[type=text], input[type=password], input:not([type])').each(function () {
    var text = $(this);
    var name = text.attr('name');
    var value = String(values[name] || '');
    text.val(value);
  });

  form.find('input[type=checkbox]').each(function () {
    var box = $(this);
    var name = box.attr('name');
    if (!(name in values))
      return;

    var boolValue = values[name];
    if (_.isString(boolValue)) {
      boolValue = (boolValue != "0");
    }

    setBoolAttribute(box, 'checked', boolValue);
  });

  form.find('input[type=radio]').each(function () {
    var box = $(this);
    var name = box.attr('name');
    if (!(name in values))
      return;

    var boolValue = (values[name] == box.attr('value'));
    setBoolAttribute(box, 'checked', boolValue);
  });

  form.find("select").each(function () {
    var select = $(this);
    var name = select.attr('name');
    if (!(name in values))
      return;

    var value = values[name];

    select.find('option').each(function () {
      var option = $(this);
      setBoolAttribute($(this), 'selected', option.val() == value);
    });
  });
}

function formatUptime(seconds, precision) {
  precision = precision || 8;

  var arr = [[86400, "days", "day"],
             [3600, "hours", "hour"],
             [60, "minutes", "minute"],
             [1, "seconds", "second"]];

  var rv = [];

  $.each(arr, function () {
    var period = this[0];
    var value = (seconds / period) >> 0;
    seconds -= value * period;
    if (value)
      rv.push(String(value) + ' ' + (value > 1 ? this[1] : this[2]));
    return !!--precision;
  });

  return rv.join(', ');
}

function postWithValidationErrors(url, data, callback, ajaxOptions) {
  if (!_.isString(data))
    data = serializeForm(data);
  var finalAjaxOptions = {
    type:'POST',
    url: url,
    data: data,
    success: continuation,
    error: continuation,
    dataType: 'json'
  };
  _.extend(finalAjaxOptions, ajaxOptions || {});
  var action = new ModalAction();
  $.ajax(finalAjaxOptions);
  return

  function continuation(data, textStatus) {
    action.finish();
    if (textStatus != 'success') {
      var status = 0;
      try {
        status = data.status // can raise exception on IE sometimes
      } catch (e) {
        // ignore
      }
      if (status >= 200 && status < 300 && data.responseText == '') {
        return callback.call(this, '', 'success');
      }

      if (status != 400 || textStatus != 'error') {
        return onUnexpectedXHRError(data);
      }

      var errorsData = $.httpData(data, null, this);
      if (!_.isArray(errorsData)) {
        if (errorsData == null)
          errorsData = "unknown reason";
        errorsData = [errorsData];
      }
      callback.call(this, errorsData, 'error');
      return;
    }

    callback.call(this, data, textStatus);
  }
}

function runFormDialog(uriOrPoster, dialogID, options) {
  options = options || {};
  var dialogQ = $('#' + dialogID);
  var form = dialogQ.find('form');
  var response = false;

  var errors = dialogQ.find('.errors');
  errors.hide();

  var poster;
  if (_.isString(uriOrPoster))
    poster = _.bind(postWithValidationErrors, null, uriOrPoster);
  else
    poster = uriOrPoster;

  function callback(data, status) {
    if (status == 'success') {
      response = data;
      hideDialog(dialogID);
      return;
    }

    if (!errors.length) {
      alert('submit failed: ' + data.join(' and '));
      return;
    }
    errors.html();
    _.each(data, function (message) {
      var li = $('<li></li>');
      li.text(message);
      errors.append(li);
    });
    errors.show();
  }

  function onSubmit(e) {
    e.preventDefault();
    if (options.validate) {
      var errors = options.validate();
      if (errors && errors.length) {
        callback(errors, 'error');
        return;
      }
    }
    poster(form, callback);
  }

  form.bind('submit', onSubmit);
  setFormValues(form, options.initialValues || {});
  showDialog(dialogID, {
    onHide: function () {
      form.unbind('submit', onSubmit);
      if (options.closeCallback) {
        options.closeCallback(response);
      }
    }
  });
}

future.getPush = function (ajaxOptions, valueTransformer, nowValue) {
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

  if (ajaxOptions.url == undefined)
    throw new Error("url is undefined");

  function sendRequest(dataCallback) {
    var options = _.extend({type: 'GET',
                            dataType: 'json',
                            error: onError,
                            success: continuation},
                           ajaxOptions);
    if (options.url.indexOf("?") < 0)
      options.url += '?waitChange=20000'
    else
      options.url += '&waitChange=20000'
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
        return onUnexpectedXHRError(xhr);

      onNoncriticalXHRError(xhr);
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

// make sure around 3 digits of value is visible. Less for for too
// small numbers
function truncateTo3Digits(value, leastScale) {
  var scale = _.detect([100, 10, 1, 0.1, 0.01, 0.001], function (v) {return value >= v;}) || 0.0001;
  if (leastScale != undefined && leastScale > scale)
    scale = leastScale;
  scale = 100 / scale;
  return Math.floor(value*scale)/scale;
}

function prepareTemplateForCell(templateName, cell) {
  cell.undefinedSlot.subscribeWithSlave(function () {
    prepareRenderTemplate(templateName);
  });
  if (cell.value === undefined)
    prepareRenderTemplate(templateName);
}

// renderCellTemplate(cell, "something");
// renderCellTemplate(cell, ["something_container", "foorbar"]);
function renderCellTemplate(cell, to, valueTransformer) {
  var template;

  if (_.isArray(to)) {
    template = to[1] + '_template';
    to = to[0];
  } else {
    template = to + "_template";
    to += '_container'
  }

  var toGetter;
  if (_.isString(to)) {
    toGetter = function () {
      return $i(to);
    }
  } else {
    toGetter = function () {
      return to;
    }
  }

  var clearSlave = new Slave(function () {
    prepareAreaUpdate($(toGetter()));
  });
  cell.undefinedSlot.subscribeWithSlave(clearSlave);
  if (cell.value === undefined)
    clearSlave.thunk(cell);

  var renderSlave = new Slave(function (cell) {
    var value = cell.value;
    if (valueTransformer)
      value = valueTransformer(value);
    renderRawTemplate(toGetter(), template, value);
  });
  cell.changedSlot.subscribeWithSlave(renderSlave);
  if (cell.value !== undefined)
    renderSlave.thunk(cell);

  return {
    cancel: function () {
      cell.changedSlot.unsubscribe(renderSlave);
      cell.undefinedSlot.unsubscribe(clearSlave);
    }
  }
}

var MultiDrawersWidget = mkClass({
  mandatoryOptions: "hashFragmentParam template elementsKey drawerCellName idPrefix".split(" "),
  initialize: function (options) {
    options = this.options = _.extend({
      placeholderCSS: '.settings-placeholder',
      placeholderContainerChildCSS: 'td',
      uriExtractor: function (e) {return e.uri;}
    }, options);

    var missingOptions = _.reject(this.mandatoryOptions, function (n) {
      return (n in options);
    });

    if (missingOptions.length)
      throw new Error("Missing mandatory option(s): " + missingOptions.join(','));

    this.openedNames = new StringSetHashFragmentCell(options.hashFragmentParam);

    if (options.actionLink) {
      configureActionHashParam(options.actionLink, $m(this, 'onActionLinkClick'));
    }

    this.subscriptions = [];
    this.reDrawElements = $m(this, 'reDrawElements');
    this.hookRedrawToCell(this.openedNames);
  },
  hookRedrawToCell: function (cell) {
    cell.subscribe(this.reDrawElements);
  },
  onActionLinkClick: function (uri, isMiddleClick) {
    this.options.actionLinkCallback(uri);
    if (isMiddleClick) {
      this.openElement(uri);
    } else
      this.toggleElement(uri);
  },
  valuesTransformer: function (elements) {
    var self = this;
    var idPrefix = self.options.idPrefix;
    var key = self.options.elementsKey;
    var drawerCellName = self.options.drawerCellName;

    var oldElementsByName = self.elementsByName || {};

    self.elementsByName = {};

    _.each(elements, function (e) {
      e[idPrefix] = _.uniqueId(idPrefix);

      var uriCell = new Cell(function (openedNames) {
        if (this.self.value || !_.include(openedNames, e[key]))
          return this.self.value;

        return self.options.uriExtractor(e);
      }, {openedNames: self.openedNames});

      var cell = e[drawerCellName] = new Cell(function (uri) {
        return future.get({url: uri}, function (childItem) {
          if (self.options.valueTransformer)
            childItem = self.options.valueTransformer(e, childItem);
          return childItem;
        });
      }, {uri: uriCell});

      var oldE = oldElementsByName[e[key]];
      var oldCell = oldE && oldE[drawerCellName];

      // use previous value if possible, but refresh it
      if (oldCell && oldCell.value) {
        cell.setValue(oldCell.value);
        cell.keepValueDuringAsync = true;
        cell.invalidate();
      }

      self.elementsByName[e[key]] = e;
    });
    return elements;
  },
  reDrawElements: function () {
    var self = this;

    var subscriptions = self.subscriptions;
    _.each(subscriptions, function (s) {
      s.cancel();
    });
    subscriptions.length = 0;

    $(self.options.placeholderCSS).hide();

    var elementsByName = self.elementsByName;
    if (!elementsByName)
      return;

    _.each(self.openedNames.value, function (name) {
      var element = elementsByName[name];
      if (!element) {
        console.log("element: ", name, "not found");
        return;
      }

      var parentNode = $i(element[self.options.idPrefix]);
      if (!parentNode) {
        console.log("should not happen");
        return;
      }

      var cell = element[self.options.drawerCellName];

      var q = $(parentNode);

      var container;
      var childCSS = self.options.placeholderContainerChildCSS;
      if (childCSS)
        container = q.find(childCSS)[0];
      else
        container = q[0];

      if (!container) {
        throw new Error("MultiDrawersWidget: bad markup!");
      }

      var s = renderCellTemplate(element[self.options.drawerCellName], [container, self.options.template]);
      subscriptions.push(s);

      q.show();
    });
  },
  toggleElement: function (name) {
    if (_.include(this.openedNames.value, name)) {
      this.closeElement(name);
    } else {
      this.openElement(name);
    }
  },
  openElement: function (name) {
    this.openedNames.addValue(name);
  },
  closeElement: function (name) {
    this.openedNames.removeValue(name);
  },
  reset: function () {
    this.openedNames.reset();
  }
});

_.extend(ViewHelpers, {
  thisElement: function (body) {
    var id = _.uniqueId("thisElement");

    AfterTemplateHooks.push(function () {
      var marker = $($i(id));
      var element = marker.parent();
      marker.remove();

      body.call(element.get(0), element);
    });

    return ["<span id='", id, "'></span>"].join('');
  },

  // assigns $.data on current element
  // use with {%= %} !
  setData: function (name, value) {
    return this.thisElement(function (thisElement) {
      $.data(thisElement.get(0), name, value);
    });
  },

  setPercentBar: function (percents) {
    return this.thisElement(function (q) {
      percents = (percents << 0); // coerces NaN and infinities to 0
      q.find('.used').css('width', String(percents)+'%')
    });
  },
  setAttribute: function (name, value) {
    return this.thisElement(function (q) {
      q.attr(name, value);
    });
  },
  specialPluralizations: {
    'copy': 'copies'
  },
  count: function (count, text) {
    if (count == null)
      return '?' + text + '(s)';
    count = Number(count);
    if (count > 1) {
      var lastWord = text.split(/\s+/).slice(-1)[0];
      var specialCase = ViewHelpers.specialPluralizations[lastWord];
      if (specialCase)
        text = specialCase;
      else
        text += 's';
    }
    return [String(count), ' ', text].join('')
  },
  renderHealthClass: function (status) {
    if (status == "healthy")
      return "up";
    else
      return "down";
  },
  formatLogTStamp: function (ts) {
    return window.formatLogTStamp(ts);
  },
  prepareQuantity: function (value, K) {
    K = K || 1024;
    var M = K*K;
    var G = M*K;
    var T = G*K;

    var t = _.detect([[T,'T'],[G,'G'],[M,'M'],[K,'K']], function (t) {return value > 1.1*t[0]});
    t = t || [1, ''];
    return t;
  },
  formatQuantity: function (value, kind, K, spacing) {
    if (spacing == null)
      spacing = '';
    if (kind == null)
      kind = 'B'; //bytes is default

    var t = ViewHelpers.prepareQuantity(value, K);
    return [truncateTo3Digits(value/t[0]), spacing, t[1], kind].join('');
  },

  renderPendingStatus: function (node) {
    if (node.clusterMembership == 'inactiveFailed') {
      if (node.pendingEject) {
        return "PENDING EJECT FAILED OVER"
      } else {
        return "FAILED OVER";
      }
    }
    if (node.pendingEject) {
      return "PENDING EJECT";
    }
    if (node.clusterMembership == 'active')
      return '';
    if (node.clusterMembership == 'inactiveAdded') {
      return 'PENDING ADD';
    }
    debugger
    throw new Error('cannot reach');
  },

  ifNull: function (value, replacement) {
    if (value == null || value == '')
      return replacement;
    return value;
  },

  stripPort: function(value) {
    return value.split(":",1);
  }

});

function genericDialog(options) {
  options = _.extend({buttons: {ok: true,
                                cancel: true},
                      modal: true,
                      fixed: true,
                      callback: function () {
                        instance.close();
                      }},
                     options);
  var text = options.text || 'No text.';
  var header = options.header || 'No Header';
  var dialogTemplate = $('#generic_dialog');
  var dialog = $('<div></div>');
  dialog.attr('class', dialogTemplate.attr('class'));
  dialog.attr('id', _.uniqueId('generic_dialog_'));
  dialogTemplate.after(dialog);
  dialog.html(dialogTemplate.html());

  dialogTemplate = null;

  function brIfy(text) {
    return _.map(text.split("\n"), escapeHTML).join("<br>");
  }

  dialog.find('.lbox_header').html(options.headerHTML || brIfy(header));
  dialog.find('.dialog-text').html(options.textHTML || brIfy(text));

  var b = options.buttons;
  if (!b.ok && !b.cancel) {
    dialog.find('.save_cancel').hide();
  } else {
    dialog.find('.save_cancel').show();
    var ok = b.ok;
    var cancel = b.cancel;

    if (ok === true)
      ok = 'OK';
    if (cancel === true)
      cancel == 'CANCEL';

    function bind(jq, on, name) {
      jq[on ? 'show' : 'hide']();
      if (on) {
        jq.bind('click', function (e) {
          e.preventDefault();
          options.callback.call(this, e, name, instance);
        });
      }
    }
    bind(dialog.find(".save_button"), ok, 'ok');
    bind(dialog.find('.cancel_button'), cancel, 'cancel');
  }

  var modal = options.modal ? new ModalAction() : null;

  showDialog(dialog, {
    onHide: function () {
      _.defer(function () {
        dialog.remove();
      });
    },
    fixed: options.fixed
  });

  var instance = {
    dialog: dialog,
    close: function () {
      if (modal)
        modal.finish();
      hideDialog(dialog);
    }
  };

  return instance;
}

function postClientErrorReport(text) {
  function ignore() {}
  $.ajax({type: 'POST',
          url: "/logClientError",
          data: text,
          success: ignore,
          error: ignore});
}

var originalOnError;
(function () {
  var sentReports = 0;
  var ErrorReportsLimit = 8;
  originalOnError = window.onerror;

  function appOnError(message, fileName, lineNo) {
    var report = [];
    if (++sentReports < ErrorReportsLimit) {
      report.push("Got unhandled error: ", message, "\nAt: ", fileName, ":", lineNo, "\n");
      var bt = collectBacktraceViaCaller();
      if (bt) {
        report.push("Backtrace:\n", bt);
      }
      if (sentReports == ErrorReportsLimit - 1) {
        report.push("Further reports will be suppressed\n")
      }
    }

    // mozilla can report errors in some cases when user leaves current page
    // so delay report sending
    _.delay(function () {
      postClientErrorReport(report.join(''));
    }, 500);

    if (originalOnError)
      originalOnError.call(window, message, fileName, lineNo);
  }
  window.onerror = appOnError;
})();

// clicks to links with href of '#<param>=' will be
// intercepted. Default action (navigating) will be prevented and body
// will be executed.
//
// Middle-clicks that open link in new tab/window will not be (and
// cannot be) intercepted
//
// We use this function to preserve other state that may be in url
// hash string in normal case, while still supporting middle-clicking.
function watchHashParamLinks(param, body) {
  param = '#' + param + '=';
  $('a').live('click', function (e) {
    var href = $(this).attr('href');
    if (href == null)
      return;
    var pos = href.indexOf(param)
    if (pos < 0)
      return;
    e.preventDefault();
    body.call(this, e, href.slice(pos + param.length));
  });
}

// used for links that do some action (like displaying certain bucket,
// dialog, ...). This function adds support for middle clicking on
// such action links.
function configureActionHashParam(param, body) {
  // this handles normal clicks (NOTE: no change to url/history is
  // done in that case)
  watchHashParamLinks(param, function (e, hash) {
    body(hash);
  });
  // this handles middle clicks. In such case the only hash fragment
  // of our url will be 'param'. We delete that param and call body
  DAO.onReady(function () {
    var value = getHashFragmentParam(param);
    if (value) {
      setHashFragmentParam(param, null);
      body(value, true);
    }
  });
}

var MountPointsStd = mkClass({
  initialize: function (paths) {
    var self = this;
    var infos = _.map(paths, function (p, i) {
      p = self.preprocessPath(p);
      return {p: p, i: i};
    });
    infos.sort(function (a,b) {return b.p.length - a.p.length});
    this.infos = infos;
  },
  preprocessPath: function (p) {
    if (p[p.length-1] != '/')
      p += '/';
    return p;
  },
  lookup: function (path) {
    path = this.preprocessPath(path);
    var info = _.detect(this.infos, function (info) {
      if (path.substring(0, info.p.length) == info.p)
        return true;
    });
    return info && info.i;
  }
});

var MountPointsWnd = mkClass(MountPointsStd, {
  preprocessPath: (function () {
    var re = /^[A-Z]:\//
    var overriden = MountPointsStd.prototype.preprocessPath;
    return function (p) {
      p = p.replace('\\', '/')
      if (re.exec(p)) { // if we're using uppercase drive letter downcase it
        p = String.fromCharCode(p.charCodeAt(0) + 0x20) + p.slice(1);
      }
      return overriden.call(this, p);
    }
  }())
});

function MountPoints(nodeInfo, paths) {
  if (nodeInfo['os'] == 'windows' || nodeInfo['os'] == 'win32')
    return new MountPointsWnd(paths);
  else
    return new MountPointsStd(paths);
}
