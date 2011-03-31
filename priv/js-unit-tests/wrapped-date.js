
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

  _.extend(cloned, methods);
  cloned.valueOf = methods.valueOf;
  cloned.toString = methods.toString;

  if (prototypeProcessor)
    prototypeProcessor(cloned, NewDate);

  var initialize = cloned.initialize;

  delete cloned.initialize;

  return NewDate;
}

mkDateWrapper.mkApplyHelper = function(count) {
  var invokation = _.map(_.range(count), function (i) {
    return "a[" + i + "]"
  }).join(", ");
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

  _.each(fields, function (name) {
    delegatedMethods.push("get" + name);
    delegatedMethods.push("set" + name);
    delegatedMethods.push("getUTC" + name);
    delegatedMethods.push("setUTC" + name);
  });

  mkDateWrapper.delegatedMethods = delegatedMethods;

  _.each(delegatedMethods, function (name) {
    mkDateWrapper.defaultMethods[name] = mkDateWrapper.mkDelegator(name);
  });
})();
