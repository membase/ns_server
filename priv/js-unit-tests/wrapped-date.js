
function mkDateWrapper(prototypeProcessor, methods) {
  var originalDate = window.Date;
  methods = methods || mkDateWrapper.defaultMethods;

  function NewDate() {
    if (!(this instanceof NewDate)) {
      var d = mkDateWrapper.applyConstructor(NewDate, arguments);
      return d.toString();
    }
    return initialize.call(this, originalDate, arguments);
  }

  NewDate.parse = function () {
    return Date.parse.apply(Date, arguments);
  }
  NewDate.UTC = function () {
    return Date.UTC.apply(Date, arguments);
  }

  var cloned = NewDate.prototype;
  var prop;
  for (prop in methods) {
    cloned[prop] = methods[prop];
  }
  cloned.valueOf = methods.valueOf;
  cloned.toString = methods.toString;

  if (prototypeProcessor)
    prototypeProcessor(cloned, NewDate);

  var initialize = cloned.initialize;

  delete cloned.initialize;

  return NewDate;
}

mkDateWrapper.range = function (start, stop, step) {
  if (arguments.length <= 1) {
    stop = start || 0;
    start = 0;
  }
  step = arguments[2] || 1;

  var len = Math.max(Math.ceil((stop - start) / step), 0);
  var idx = 0;
  var range = new Array(len);

  while(idx < len) {
    range[idx++] = start;
    start += step;
  }

  return range;
}

mkDateWrapper.each = function (obj, iterator, context) {
  for (var i = 0, l = obj.length; i < l; i++) {
    i in obj && iterator.call(context, obj[i], i, obj);
  }
}


mkDateWrapper.mkApplyHelper = function(count) {
  var invokation = [];
  this.each(this.range(count), function (i) {
    invokation.push("a[" + i + "]")
  });
  invokation = invokation.join(", ");
  return Function("c", "a", "return new c(" + invokation + ");")
}

mkDateWrapper.applyConstructor = function (constructor, args) {
  var cache = mkDateWrapper.applyConstructor.cache;
  if (!cache[args.length]) {
    cache[args.length] = mkDateWrapper.mkApplyHelper(args.length);
  }

  return cache[args.length](constructor, args);
}
mkDateWrapper.applyConstructor.cache = [];

mkDateWrapper.defaultMethods = {
  initialize: function (originalDate, args) {
    this._originalPrototype = originalDate.prototype;
    this._original = mkDateWrapper.applyConstructor(originalDate, args);
  }
};

mkDateWrapper.mkDelegator = function (name) {
  return function () {
    var rv = this._originalPrototype[name].apply(this._original, arguments);
    if (rv === this._original)
      rv = this;
    return rv;
  }
}

;(function () {
  var delegatedMethods = ("toString toDateString toTimeString toLocaleString" +
                          " toLocaleDateString toLocaleTimeString valueOf getTimezoneOffset" +
                          " toUTCString getTime setTime").split(" ");
  var fields = "FullYear Month Date Day Hours Minutes Seconds Milliseconds".split(" ");

  mkDateWrapper.each(fields, function (name) {
    delegatedMethods.push("get" + name);
    delegatedMethods.push("set" + name);
    delegatedMethods.push("getUTC" + name);
    delegatedMethods.push("setUTC" + name);
  });

  mkDateWrapper.delegatedMethods = delegatedMethods;

  mkDateWrapper.each(delegatedMethods, function (name) {
    mkDateWrapper.defaultMethods[name] = mkDateWrapper.mkDelegator(name);
  });
})();
