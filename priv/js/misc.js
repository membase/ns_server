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
  var tracer = function() {
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

function escapeHTML() {
  return String(arguments[0]).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
}

// Based on: http://ejohn.org/blog/javascript-micro-templating/
// Simple JavaScript Templating
// John Resig - http://ejohn.org/ - MIT Licensed
;(function(){
  var cache = {};

  this.tmpl = function tmpl(str, data){
    // Figure out if we're getting a template, or if we need to
    // load the template - and be sure to cache the result.

    var fn = !/\W/.test(str) && (cache[str] = cache[str] ||
                                 tmpl(document.getElementById(str).innerHTML));

    if (!fn) {
      var body = "var p=[],print=function(){p.push.apply(p,arguments);}," +
        "h=window.escapeHTML;" +

      // Introduce the data as local variables using with(){}
      "with(obj){p.push('" +

      // Convert the template into pure JavaScript
      str
      .replace(/[\r\t\n]/g, " ")
      .split("{%").join("\t")
      .replace(/((^|%})[^\t]*)'/g, "$1\r") //'
      .replace(/\t=(.*?)%}/g, "',$1,'")
      .split("\t").join("');")
      .split("%}").join("p.push('")
      .split("\r").join("\\'")
        + "');}return p.join('');"

      // Generate a reusable function that will serve as a template
      // generator (and which will be cached).
      fn = new Function("obj", body);
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

function overlayWithSpinner(jq) {
  if ($.isString(jq))
    jq = $(jq);
  var height = jq.height();
  var width = jq.width();
  var html = $(SpinnerHTML, document);
  var pos = jq.position();
  var realBackgroundColor = getRealBackgroundColor(jq);
  var newStyle = {
    width: width+'px',
    height: height+'px',
    lineHeight: height+'px',
    position: 'absolute',
    'background-color': realBackgroundColor,
    'z-level': 9999,
    top: pos.top + 'px',
    left: pos.lext + 'px'
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

function renderTemplate(key, data) {
  var to = key + '_container';
  var from = key + '_template';
  if ($.isArray(data)) {
    data = {rows:data};
  }
  $i(to).innerHTML = tmpl(from, data);
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

  return function () {
    return f.apply(self, arguments);
  }
}

var $i = function (id) {
  return document.getElementById(id);
}

// stolen from MIT-licensed prototype.js http://www.prototypejs.org/
var functionArgumentNames = function(f) {
  var names = f.toString().match(/^[\s\(]*function[^(]*\(([^\)]*)\)/)[1]
                                 .replace(/\s+/g, '').split(',');
  return names.length == 1 && !names[0] ? [] : names;
};

function jsComparator(a,b) {
  return (a == b) ? 0 : ((a < b) ? -1 : 1);
}

function reloadApp() {
  prepareAreaUpdate($(document.body));
  window.location.reload();
}

// this thing will ensure that a back button pressed during some modal
// action will reload the page, so that we don't have to face issues
// caused by unexpected change of state
// TODO: implement
function ModalAction() {
  this.finish = function () {
  }
}
