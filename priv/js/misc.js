if (!('console' in window))
  window.console = {log: function () {}};

function getBacktrace() {
  try {
    throw new Error();
  } catch (e) {
    return e.stack;
  }
};

function traceMethodCalls(object, methodName) {
  var original = object[methodName];
  function tracer() {
    var args = $.makeArray(arguments);
    console.log("traceIn:",object,".",methodName,"(",args,")");
    try {
      var rv = original.apply(this, arguments);
      console.log("traceOut: rv = ",rv);
      return rv;
    } catch (e) {
      console.log("traceExc: e = ", e);
      throw e;
    }
  }
  object[methodName] = tracer;
}

// creates function with body of F, but environment ENV
// USE WITH EXTREME CARE
function reinterpretInEnv(f, env) {
  var keys = [];
  var vals = [];
  for (var k in env) {
    keys.push(k);
    vals.push(env[k]);
  }
  var body = 'return ' + String(f);
  body = body.replace(/^return function\s+[^(]*\(/m, 'return function (');
  var maker = Function.apply(Function, keys.concat([body]));
  return maker.apply(null, vals);
}

// ;(function () {
//   var f = function () {
//     alert('f:' + f);
//   }
//   f();
//   reinterpretInEnv(f, {f: 'alk'})();
// })();

function escapeHTML() {
  return String(arguments[0]).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
}

function escapeJS(string) {
  return String(string).replace(/\\/g, '\\\\').replace(/["']/g, '\\$&');
}

function renderJSLink(functionName, arg, prefix) {
  prefix = prefix || "javascript:"
  return escapeHTML(prefix + functionName + "('" + escapeJS(arg) + "')")
}

_.template = function (str, data) {
  function translateTemplate(templ) {
    var openRE = /{%=?/g;
    var closeRE = /%}/g;

    var len = templ.length;
    var match, match2;
    var str;

    var res = ['var p=[],print=function(){p.push.apply(p,arguments);};',
               'with(obj){'];
    var literals = {};
    var toPush;

    closeRE.lastIndex = 0;

    while (closeRE.lastIndex < len) {
      openRE.lastIndex = closeRE.lastIndex;

      match = openRE.exec(templ);
      if (!match)
        str = templ.slice(closeRE.lastIndex);
      else
        str = templ.slice(closeRE.lastIndex, match.index);

      function addOut(expr) {
        if (!toPush)
          res.push(toPush = []);
        toPush.push(expr);
      }

      var id = _.uniqueId("__STR");
      literals[id] = str;

      addOut(id);

      if (!match)
        break;

      closeRE.lastIndex = openRE.lastIndex;
      match2 = closeRE.exec(templ);

      if (!match2)
        throw new Error("missing %}");

      str = templ.slice(openRE.lastIndex, match2.index);
      if (match[0] == '{%=') {
        addOut(str);
      } else {
        res.push(str);
        toPush = null;
      }
    }

    res.push("};\nreturn p.join('');"); // close 'with'

    var body = _.map(res, function (e) {
      if (e instanceof Array) {
        return "p.push(" + e.join(", ") + ");"
      }
      return e;
    }).join("\n");

    return [body, literals];
  }

  try {
    var arr = translateTemplate(str);
    var body = arr[0];
    var literals = arr[1];
    // add some common helpers into scope
    _.extend(literals, {
      h: escapeHTML,
      V: ViewHelpers,
      jsLink: renderJSLink});

    var fn = reinterpretInEnv("function (obj) {\n" + body + "\n}", literals);
  } catch (e) {
    try {
      e.templateBody = body;
      e.templateSource = str;
    } catch (e2) {} // sometimes exceptions do not allow expando props
    throw e;
  }

  return data ? fn(data) : fn;
}

// Based on: http://ejohn.org/blog/javascript-micro-templating/
// Simple JavaScript Templating
// John Resig - http://ejohn.org/ - MIT Licensed
;(function(){
  var cache = {};

  function handleURLEncodedScriptlets(str) {
    var re = /%7B(?:%25|%)=.+?(?:%25|%)%7D/ig;
    var match;
    var res = [];
    var lastIndex = 0;
    var prematch;
    while ((match = re.exec(str))) {
      prematch = str.substring(lastIndex, match.index);
      if (prematch.length)
        res.push(prematch);
      // firefox can be a bit wrong here, forgetting to escape single '%'
      var matchStr = match[0].replace('%=', '%25=').replace('%%7D', '%25%7D');
      res.push(decodeURIComponent(matchStr));
      lastIndex = re.lastIndex;
    }

    // fastpath
    if (!lastIndex)
      return str;

    prematch = str.substring(lastIndex);
    if (prematch.length)
      res.push(prematch);

    return res.join('');
  }

  this.tmpl = function tmpl(str, data){
    // Figure out if we're getting a template, or if we need to
    // load the template - and be sure to cache the result.

    var fn = !/\W/.test(str) && (cache[str] = cache[str] ||
                                 tmpl(document.getElementById(str).innerHTML));

    if (!fn) {
      str = handleURLEncodedScriptlets(str);
      // Generate a reusable function that will serve as a template
      // generator (and which will be cached).
      fn = _.template(str);
    }

    // Provide some basic currying to the user
    return data ? fn( data ) : fn;
  };
})();

$.isString = function (s) {
  return typeof(s) == "string" || (s instanceof String);
}

var SpinnerHTML = "<div class='spinner'><span>Loading...</span></div>";

function prepareAreaUpdate(jq) {
  if ($.isString(jq))
    jq = $(jq);
  var height = jq.height();
  var width = jq.width();
  if (height < 50)
    height = 50;
  if (width < 100)
    width = 100;
  var replacement = $(SpinnerHTML, document);
  replacement.css('width', width + 'px').css('height', height + 'px').css('lineHeight', height + 'px');
  jq.html("");
  jq.append(replacement);
}

function getRealBackgroundColor(jq) {
  while (true) {
    if (!jq.length)
      return 'transparent';
    var rv = jq.css('background-color');
    if (rv != 'transparent' && rv != 'inherit')
      return rv;
    jq = jq.parent();
  }
}

function overlayWithSpinner(jq, backgroundColor) {
  if ($.isString(jq))
    jq = $(jq);
  var height = jq.height();
  var width = jq.width();
  var html = $(SpinnerHTML, document);
  var pos = jq.position();
  var newStyle = {
    width: width+'px',
    height: height+'px',
    lineHeight: height+'px',
    'margin-top': jq.css('margin-top'),
    'margin-bottom': jq.css('margin-bottom'),
    'margin-left': jq.css('margin-left'),
    'margin-right': jq.css('margin-right'),
    'padding-top': jq.css('padding-top'),
    'padding-bottom': jq.css('padding-bottom'),
    'padding-left': jq.css('padding-left'),
    'padding-right': jq.css('padding-right'),
    'border-width-top': jq.css('border-width-top'),
    'border-width-bottom': jq.css('border-width-bottom'),
    'border-width-left': jq.css('border-width-left'),
    'border-width-right': jq.css('border-width-right'),
    position: 'absolute',
    'z-index': '9999',
    top: pos.top + 'px',
    left: pos.left + 'px'
  }
  if (jq.css('position') == 'fixed') {
    newStyle.position = 'fixed';
    var offsetParent = jq.offsetParent().get(0);
    newStyle.top = (parseFloat(newStyle.top) - offsetParent.scrollTop - offsetParent.parentNode.scrollTop) + 'px';
    newStyle.left = (parseFloat(newStyle.left) - offsetParent.scrollLeft - offsetParent.parentNode.scrollLeft) + 'px';
  }
  if (backgroundColor !== false) {
    var realBackgroundColor = backgroundColor || getRealBackgroundColor(jq);
    newStyle['background-color'] = realBackgroundColor;
  }
  _.each(newStyle, function (value, key) {
    html.css(key, value);
  })
  jq.after(html);

  return {
    remove: function () {
      html.remove();
    }
  };
}

function prepareRenderTemplate() {
  $.each($.makeArray(arguments), function () {
    prepareAreaUpdate('#'+ this + '_container');
  });
}

var ViewHelpers = {};
var AfterTemplateHooks;

function renderTemplate(key, data) {
  var to = key + '_container';
  var from = key + '_template';
  if ($.isArray(data)) {
    data = {rows:data};
  }

  var oldHooks = AfterTemplateHooks;
  AfterTemplateHooks = [];
  try {
    var fn = tmpl(from);
    var value = fn(data)
    $i(to).innerHTML = value;

    _.each(AfterTemplateHooks, function (hook) {
      hook.call();
    });

    $(window).trigger('template:rendered');
  } catch (e) {
    if (confirm('Template error:' + String(fn) + ', ' + e.templateBody)) {
      debugger
      renderTemplate(key, data);
    }
    throw e;
  } finally {
    AfterTemplateHooks = oldHooks;
  }
}

function $m(self, method, klass) {
  if (klass) {
    var f = klass.prototype[method];
    if (!f || !f.apply)
      throw new Error("Bogus method: " + method + " on prototype of: " + klass);
  } else {
    var f = self[method];
    if (!f || !f.apply)
      throw new Error("Bogus method: " + method + " on object: " + self);
  }

  function rv () {
    return f.apply(self, arguments);
  }

  // TODO: this is debugging measure. Disable it later.
  rv['$m'] = _.toArray(arguments);
  rv['$m.f'] = f;

  return rv;
}

function $i(id) {
  return document.getElementById(id);
}

// stolen from MIT-licensed prototype.js http://www.prototypejs.org/
function functionArgumentNames(f) {
  var names = f.toString().match(/^[\s\(]*function[^(]*\(([^\)]*)\)/)[1]
                                 .replace(/\s+/g, '').split(',');
  return names.length == 1 && !names[0] ? [] : names;
};

function jsComparator(a,b) {
  return (a == b) ? 0 : ((a < b) ? -1 : 1);
}

function reloadApp(middleCallback) {
  prepareAreaUpdate($(document.body));
  if (middleCallback)
    middleCallback();
  window.location.reload();
}

// this thing ensures that a back button pressed during some modal
// action (waiting http POST response, for example) will reload the
// page, so that we don't have to face issues caused by unexpected
// change of state
(function () {
  var modalLevel = 0;

  function ModalAction() {
    modalLevel++;
    this.finish = function () {
      modalLevel--;
      delete this.finish;
    }
  }

  window.ModalAction = ModalAction;

  ModalAction.isActive = function () {
    return modalLevel;
  }

  ModalAction.leavingNow = function () {
    if (modalLevel) {
      reloadApp();
    }
  }

  $(function () {
    // first event is skipped, 'cause it's manually triggered by us
    var hadFirstEvent = false;
    $(window).bind('hashchange', function () {
      if (hadFirstEvent)
        ModalAction.leavingNow();
      else
        hadFirstEvent = true;
    })
  });
})();

function isBlank(e) {
  return e == null || !e.length;
}

(function () {
  var plannedState;
  var timeoutId;

  function planPushState(state) {
    plannedState = state;
    if (!timeoutId) {
      timeoutId = setTimeout(function () {
        $.bbq.pushState(plannedState, 2);
        plannedState = undefined;
        timeoutId = undefined;
      }, 100);
      $(window).trigger('hashchange');
    }
  }
  function setHashFragmentParam(name, value) {
    var state = _.extend({}, plannedState || $.bbq.getState());
    if (value == null) {
      delete state[name];
      planPushState(state);
    } else if (value != state[name]) {
      state[name] = value;
      planPushState(state);
    }
  }

  function getHashFragmentParam(name) {
    return (plannedState && plannedState[name]) || $.bbq.getState(name);
  }

  window.setHashFragmentParam = setHashFragmentParam;
  window.getHashFragmentParam = getHashFragmentParam;
})();

function watchHashParamChange(param, defaultValue, callback) {
  if (!callback) {
    callback = defaultValue;
    defaultValue = undefined;
  }

  var oldValue;
  var firstTime = true;
  $(function () {
    $(window).bind('hashchange', function () {
      var newValue = getHashFragmentParam(param) || defaultValue;
      if (!firstTime && oldValue == newValue)
        return;
      firstTime = false;
      oldValue = newValue;
      return callback.apply(this, [newValue].concat($.makeArray(arguments)));
    });
  });
}

function showDialog(idOrJQ, options) {
  var jq = _.isString(idOrJQ) ? $($i(idOrJQ)) : idOrJQ;
  options = options || {};
  var onHashChange;

  $(window).bind('hashchange', onHashChange = function () {
    hideDialog(jq);
  });

  jq.jqm({modal:true,
          onHide: function (h) {
            $(window).unbind('hashchange', onHashChange);

            // prevent closing if modal action is in progress
            if (ModalAction.isActive()) {
              // copied from jqmodal itself
              h.w.hide() && h.o && h.o.remove();
              return showDialog(idOrJQ, options);
            }

            if (options.onHide)
              options.onHide(idOrJQ);
            // copied from jqmodal itself
            h.w.hide() && h.o && h.o.remove();
          }}).jqmShow();
}

function hideDialog(id) {
  if (_.isString(id))
    id = $($i(id));
  id.jqm().jqmHide();
  ModalAction.leavingNow();
}
