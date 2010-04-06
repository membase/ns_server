function __topEval() {
  return eval("(function () {return (" + String(arguments[0]) + ");})();");
}

function mkMethodWrapper (method, superClass, methodName) {
  return function () {
    var args = $.makeArray(arguments);
    var _super = $m(this, methodName, superClass);
    args.unshift(_super);
    return method.apply(this, args);
  }
}

function mkClass(methods) {
  if (_.isFunction(methods)) {
    var superclass = methods;
    var origMethods = arguments[1];

    var meta = new Function();
    meta.prototype = superclass.prototype;

    methods = _.extend(new meta, origMethods);

    _.each(origMethods, function (method, methodName) {
      if (_.isFunction(method) && functionArgumentNames(method)[0] == '$super') {
        methods[methodName] = mkMethodWrapper(method, superclass, methodName);
      }
    });
  } else {
    methods = _.extend({}, methods);
  }

  var constructor = __topEval(function () {
    if (this.initialize)
      return this.initialize.apply(this, arguments);
  });

  methods.constructor = constructor;
  constructor.prototype = methods;

  return constructor;
}
