(function webpackUniversalModuleDefinition(root, factory) {
	if(typeof exports === 'object' && typeof module === 'object')
		module.exports = factory();
	else if(typeof define === 'function' && define.amd)
		define([], factory);
	else if(typeof exports === 'object')
		exports["ui.router"] = factory();
	else
		root["ui.router"] = factory();
})(this, function() {
return /******/ (function(modules) { // webpackBootstrap
/******/ 	// The module cache
/******/ 	var installedModules = {};

/******/ 	// The require function
/******/ 	function __webpack_require__(moduleId) {

/******/ 		// Check if module is in cache
/******/ 		if(installedModules[moduleId])
/******/ 			return installedModules[moduleId].exports;

/******/ 		// Create a new module (and put it into the cache)
/******/ 		var module = installedModules[moduleId] = {
/******/ 			exports: {},
/******/ 			id: moduleId,
/******/ 			loaded: false
/******/ 		};

/******/ 		// Execute the module function
/******/ 		modules[moduleId].call(module.exports, module, module.exports, __webpack_require__);

/******/ 		// Flag the module as loaded
/******/ 		module.loaded = true;

/******/ 		// Return the exports of the module
/******/ 		return module.exports;
/******/ 	}


/******/ 	// expose the modules object (__webpack_modules__)
/******/ 	__webpack_require__.m = modules;

/******/ 	// expose the module cache
/******/ 	__webpack_require__.c = installedModules;

/******/ 	// __webpack_public_path__
/******/ 	__webpack_require__.p = "";

/******/ 	// Load entry module and return exports
/******/ 	return __webpack_require__(0);
/******/ })
/************************************************************************/
/******/ ([
/* 0 */
/***/ function(module, exports, __webpack_require__) {

	module.exports = __webpack_require__(1);


/***/ },
/* 1 */
/***/ function(module, exports, __webpack_require__) {

	function __export(m) {
	    for (var p in m) if (!exports.hasOwnProperty(p)) exports[p] = m[p];
	}
	__export(__webpack_require__(2));
	__export(__webpack_require__(53));
	__export(__webpack_require__(54));
	__export(__webpack_require__(55));
	__export(__webpack_require__(56));
	__export(__webpack_require__(57));
	Object.defineProperty(exports, "__esModule", { value: true });
	exports.default = "ui.router";
	//# sourceMappingURL=ng1.js.map

/***/ },
/* 2 */
/***/ function(module, exports, __webpack_require__) {

	var common = __webpack_require__(3);
	exports.common = common;
	var params = __webpack_require__(19);
	exports.params = params;
	var path = __webpack_require__(37);
	exports.path = path;
	var resolve = __webpack_require__(39);
	exports.resolve = resolve;
	var state = __webpack_require__(15);
	exports.state = state;
	var transition = __webpack_require__(12);
	exports.transition = transition;
	var url = __webpack_require__(45);
	exports.url = url;
	var view = __webpack_require__(49);
	exports.view = view;
	var router_1 = __webpack_require__(51);
	exports.Router = router_1.Router;
	//# sourceMappingURL=ui-router.js.map

/***/ },
/* 3 */
/***/ function(module, exports, __webpack_require__) {

	function __export(m) {
	    for (var p in m) if (!exports.hasOwnProperty(p)) exports[p] = m[p];
	}
	__export(__webpack_require__(4));
	__export(__webpack_require__(6));
	__export(__webpack_require__(5));
	__export(__webpack_require__(7));
	__export(__webpack_require__(8));
	__export(__webpack_require__(9));
	//# sourceMappingURL=module.js.map

/***/ },
/* 4 */
/***/ function(module, exports, __webpack_require__) {

	var predicates_1 = __webpack_require__(5);
	var hof_1 = __webpack_require__(6);
	var angular = window.angular;
	exports.fromJson = angular && angular.fromJson || _fromJson;
	exports.toJson = angular && angular.toJson || _toJson;
	exports.copy = angular && angular.copy || _copy;
	exports.forEach = angular && angular.forEach || _forEach;
	exports.extend = angular && angular.extend || _extend;
	exports.equals = angular && angular.equals || _equals;
	exports.identity = function (x) { return x; };
	exports.noop = function () { return undefined; };
	exports.abstractKey = 'abstract';
	function bindFunctions(from, to, bindTo, fnNames) {
	    if (fnNames === void 0) { fnNames = Object.keys(from); }
	    return fnNames.filter(function (name) { return typeof from[name] === 'function'; })
	        .forEach(function (name) { return to[name] = from[name].bind(bindTo); });
	}
	exports.bindFunctions = bindFunctions;
	exports.inherit = function (parent, extra) {
	    return exports.extend(new (exports.extend(function () { }, { prototype: parent }))(), extra);
	};
	var restArgs = function (args, idx) {
	    if (idx === void 0) { idx = 0; }
	    return Array.prototype.concat.apply(Array.prototype, Array.prototype.slice.call(args, idx));
	};
	var inArray = function (array, obj) { return array.indexOf(obj) !== -1; };
	exports.removeFrom = hof_1.curry(function (array, obj) {
	    var idx = array.indexOf(obj);
	    if (idx >= 0)
	        array.splice(idx, 1);
	    return array;
	});
	function defaults(opts) {
	    if (opts === void 0) { opts = {}; }
	    var defaultsList = [];
	    for (var _i = 1; _i < arguments.length; _i++) {
	        defaultsList[_i - 1] = arguments[_i];
	    }
	    var defaults = merge.apply(null, [{}].concat(defaultsList));
	    return exports.extend({}, defaults, pick(opts || {}, Object.keys(defaults)));
	}
	exports.defaults = defaults;
	function merge(dst) {
	    var objs = [];
	    for (var _i = 1; _i < arguments.length; _i++) {
	        objs[_i - 1] = arguments[_i];
	    }
	    exports.forEach(objs, function (obj) {
	        exports.forEach(obj, function (value, key) {
	            if (!dst.hasOwnProperty(key))
	                dst[key] = value;
	        });
	    });
	    return dst;
	}
	exports.merge = merge;
	exports.mergeR = function (memo, item) { return exports.extend(memo, item); };
	function ancestors(first, second) {
	    var path = [];
	    for (var n in first.path) {
	        if (first.path[n] !== second.path[n])
	            break;
	        path.push(first.path[n]);
	    }
	    return path;
	}
	exports.ancestors = ancestors;
	function equalForKeys(a, b, keys) {
	    if (keys === void 0) { keys = Object.keys(a); }
	    for (var i = 0; i < keys.length; i++) {
	        var k = keys[i];
	        if (a[k] != b[k])
	            return false;
	    }
	    return true;
	}
	exports.equalForKeys = equalForKeys;
	function pickOmitImpl(predicate, obj) {
	    var objCopy = {}, keys = restArgs(arguments, 2);
	    for (var key in obj) {
	        if (predicate(keys, key))
	            objCopy[key] = obj[key];
	    }
	    return objCopy;
	}
	function pick(obj) { return pickOmitImpl.apply(null, [inArray].concat(restArgs(arguments))); }
	exports.pick = pick;
	function omit(obj) { return pickOmitImpl.apply(null, [hof_1.not(inArray)].concat(restArgs(arguments))); }
	exports.omit = omit;
	function pluck(collection, propName) {
	    return map(collection, hof_1.prop(propName));
	}
	exports.pluck = pluck;
	function filter(collection, callback) {
	    var arr = predicates_1.isArray(collection), result = arr ? [] : {};
	    var accept = arr ? function (x) { return result.push(x); } : function (x, key) { return result[key] = x; };
	    exports.forEach(collection, function (item, i) {
	        if (callback(item, i))
	            accept(item, i);
	    });
	    return result;
	}
	exports.filter = filter;
	function find(collection, callback) {
	    var result;
	    exports.forEach(collection, function (item, i) {
	        if (result)
	            return;
	        if (callback(item, i))
	            result = item;
	    });
	    return result;
	}
	exports.find = find;
	function map(collection, callback) {
	    var result = predicates_1.isArray(collection) ? [] : {};
	    exports.forEach(collection, function (item, i) { return result[i] = callback(item, i); });
	    return result;
	}
	exports.map = map;
	exports.values = function (obj) { return Object.keys(obj).map(function (key) { return obj[key]; }); };
	exports.allTrueR = function (memo, elem) { return memo && elem; };
	exports.anyTrueR = function (memo, elem) { return memo || elem; };
	exports.unnestR = function (memo, elem) { return memo.concat(elem); };
	exports.flattenR = function (memo, elem) { return predicates_1.isArray(elem) ? memo.concat(elem.reduce(exports.flattenR, [])) : pushR(memo, elem); };
	function pushR(arr, obj) { arr.push(obj); return arr; }
	exports.unnest = function (arr) { return arr.reduce(exports.unnestR, []); };
	exports.flatten = function (arr) { return arr.reduce(exports.flattenR, []); };
	function assertPredicate(fn, errMsg) {
	    if (errMsg === void 0) { errMsg = "assert failure"; }
	    return function (obj) {
	        if (!fn(obj))
	            throw new Error(predicates_1.isFunction(errMsg) ? errMsg(obj) : errMsg);
	        return true;
	    };
	}
	exports.assertPredicate = assertPredicate;
	exports.pairs = function (object) { return Object.keys(object).map(function (key) { return [key, object[key]]; }); };
	function arrayTuples() {
	    var arrayArgs = [];
	    for (var _i = 0; _i < arguments.length; _i++) {
	        arrayArgs[_i - 0] = arguments[_i];
	    }
	    if (arrayArgs.length === 0)
	        return [];
	    var length = arrayArgs.reduce(function (min, arr) { return Math.min(arr.length, min); }, 9007199254740991);
	    return Array.apply(null, Array(length)).map(function (ignored, idx) { return arrayArgs.map(function (arr) { return arr[idx]; }); });
	}
	exports.arrayTuples = arrayTuples;
	function applyPairs(memo, keyValTuple) {
	    var key, value;
	    if (predicates_1.isArray(keyValTuple))
	        key = keyValTuple[0], value = keyValTuple[1];
	    if (!predicates_1.isString(key))
	        throw new Error("invalid parameters to applyPairs");
	    memo[key] = value;
	    return memo;
	}
	exports.applyPairs = applyPairs;
	function fnToString(fn) {
	    var _fn = predicates_1.isArray(fn) ? fn.slice(-1)[0] : fn;
	    return _fn && _fn.toString() || "undefined";
	}
	exports.fnToString = fnToString;
	function maxLength(max, str) {
	    if (str.length <= max)
	        return str;
	    return str.substr(0, max - 3) + "...";
	}
	exports.maxLength = maxLength;
	function padString(length, str) {
	    while (str.length < length)
	        str += " ";
	    return str;
	}
	exports.padString = padString;
	function tail(arr) {
	    return arr.length && arr[arr.length - 1] || undefined;
	}
	exports.tail = tail;
	function _toJson(obj) {
	    return JSON.stringify(obj);
	}
	function _fromJson(json) {
	    return predicates_1.isString(json) ? JSON.parse(json) : json;
	}
	function _copy(src, dest) {
	    if (dest)
	        Object.keys(dest).forEach(function (key) { return delete dest[key]; });
	    if (!dest)
	        dest = {};
	    return exports.extend(dest, src);
	}
	function _forEach(obj, cb, _this) {
	    if (predicates_1.isArray(obj))
	        return obj.forEach(cb, _this);
	    Object.keys(obj).forEach(function (key) { return cb(obj[key], key); });
	}
	function _copyProps(to, from) { Object.keys(from).forEach(function (key) { return to[key] = from[key]; }); return to; }
	function _extend(toObj, rest) {
	    return restArgs(arguments, 1).filter(exports.identity).reduce(_copyProps, toObj);
	}
	function _equals(o1, o2) {
	    if (o1 === o2)
	        return true;
	    if (o1 === null || o2 === null)
	        return false;
	    if (o1 !== o1 && o2 !== o2)
	        return true;
	    var t1 = typeof o1, t2 = typeof o2;
	    if (t1 !== t2 || t1 !== 'object')
	        return false;
	    var tup = [o1, o2];
	    if (hof_1.all(predicates_1.isArray)(tup))
	        return _arraysEq(o1, o2);
	    if (hof_1.all(predicates_1.isDate)(tup))
	        return o1.getTime() === o2.getTime();
	    if (hof_1.all(predicates_1.isRegExp)(tup))
	        return o1.toString() === o2.toString();
	    if (hof_1.all(predicates_1.isFunction)(tup))
	        return true;
	    var predicates = [predicates_1.isFunction, predicates_1.isArray, predicates_1.isDate, predicates_1.isRegExp];
	    if (predicates.map(hof_1.any).reduce(function (b, fn) { return b || !!fn(tup); }, false))
	        return false;
	    var key, keys = {};
	    for (key in o1) {
	        if (!_equals(o1[key], o2[key]))
	            return false;
	        keys[key] = true;
	    }
	    for (key in o2) {
	        if (!keys[key])
	            return false;
	    }
	    return true;
	}
	function _arraysEq(a1, a2) {
	    if (a1.length !== a2.length)
	        return false;
	    return arrayTuples(a1, a2).reduce(function (b, t) { return b && _equals(t[0], t[1]); }, true);
	}
	//# sourceMappingURL=common.js.map

/***/ },
/* 5 */
/***/ function(module, exports, __webpack_require__) {

	var hof_1 = __webpack_require__(6);
	var toStr = Object.prototype.toString;
	var tis = function (t) { return function (x) { return typeof (x) === t; }; };
	exports.isUndefined = tis('undefined');
	exports.isDefined = hof_1.not(exports.isUndefined);
	exports.isNull = function (o) { return o === null; };
	exports.isFunction = tis('function');
	exports.isNumber = tis('number');
	exports.isString = tis('string');
	exports.isObject = function (x) { return x !== null && typeof x === 'object'; };
	exports.isArray = Array.isArray;
	exports.isDate = function (x) { return toStr.call(x) === '[object Date]'; };
	exports.isRegExp = function (x) { return toStr.call(x) === '[object RegExp]'; };
	function isInjectable(val) {
	    if (exports.isArray(val) && val.length) {
	        var head = val.slice(0, -1), tail = val.slice(-1);
	        return !(head.filter(hof_1.not(exports.isString)).length || tail.filter(hof_1.not(exports.isFunction)).length);
	    }
	    return exports.isFunction(val);
	}
	exports.isInjectable = isInjectable;
	exports.isPromise = hof_1.and(exports.isObject, hof_1.pipe(hof_1.prop('then'), exports.isFunction));
	//# sourceMappingURL=predicates.js.map

/***/ },
/* 6 */
/***/ function(module, exports) {

	function curry(fn) {
	    var initial_args = [].slice.apply(arguments, [1]);
	    var func_args_length = fn.length;
	    function curried(args) {
	        if (args.length >= func_args_length)
	            return fn.apply(null, args);
	        return function () {
	            return curried(args.concat([].slice.apply(arguments)));
	        };
	    }
	    return curried(initial_args);
	}
	exports.curry = curry;
	function compose() {
	    var args = arguments;
	    var start = args.length - 1;
	    return function () {
	        var i = start, result = args[start].apply(this, arguments);
	        while (i--)
	            result = args[i].call(this, result);
	        return result;
	    };
	}
	exports.compose = compose;
	function pipe() {
	    var funcs = [];
	    for (var _i = 0; _i < arguments.length; _i++) {
	        funcs[_i - 0] = arguments[_i];
	    }
	    return compose.apply(null, [].slice.call(arguments).reverse());
	}
	exports.pipe = pipe;
	exports.prop = function (name) { return function (obj) { return obj && obj[name]; }; };
	exports.propEq = curry(function (name, val, obj) { return obj && obj[name] === val; });
	exports.parse = function (name) { return pipe.apply(null, name.split(".").map(exports.prop)); };
	exports.not = function (fn) { return function () {
	    var args = [];
	    for (var _i = 0; _i < arguments.length; _i++) {
	        args[_i - 0] = arguments[_i];
	    }
	    return !fn.apply(null, args);
	}; };
	function and(fn1, fn2) {
	    return function () {
	        var args = [];
	        for (var _i = 0; _i < arguments.length; _i++) {
	            args[_i - 0] = arguments[_i];
	        }
	        return fn1.apply(null, args) && fn2.apply(null, args);
	    };
	}
	exports.and = and;
	function or(fn1, fn2) {
	    return function () {
	        var args = [];
	        for (var _i = 0; _i < arguments.length; _i++) {
	            args[_i - 0] = arguments[_i];
	        }
	        return fn1.apply(null, args) || fn2.apply(null, args);
	    };
	}
	exports.or = or;
	exports.all = function (fn1) { return function (arr) { return arr.reduce(function (b, x) { return b && !!fn1(x); }, true); }; };
	exports.any = function (fn1) { return function (arr) { return arr.reduce(function (b, x) { return b || !!fn1(x); }, false); }; };
	exports.none = exports.not(exports.any);
	exports.is = function (ctor) { return function (obj) { return (obj != null && obj.constructor === ctor || obj instanceof ctor); }; };
	exports.eq = function (val) { return function (other) { return val === other; }; };
	exports.val = function (v) { return function () { return v; }; };
	function invoke(fnName, args) {
	    return function (obj) { return obj[fnName].apply(obj, args); };
	}
	exports.invoke = invoke;
	function pattern(struct) {
	    return function (x) {
	        for (var i = 0; i < struct.length; i++) {
	            if (struct[i][0](x))
	                return struct[i][1](x);
	        }
	    };
	}
	exports.pattern = pattern;
	//# sourceMappingURL=hof.js.map

/***/ },
/* 7 */
/***/ function(module, exports) {

	var notImplemented = function (fnname) { return function () {
	    throw new Error(fnname + "(): No coreservices implementation for UI-Router is loaded. You should include one of: ['angular1.js']");
	}; };
	var services = {
	    $q: undefined,
	    $injector: undefined,
	    location: {},
	    locationConfig: {},
	    template: {}
	};
	exports.services = services;
	["replace", "url", "path", "search", "hash", "onChange"]
	    .forEach(function (key) { return services.location[key] = notImplemented(key); });
	["port", "protocol", "host", "baseHref", "html5Mode", "hashPrefix"]
	    .forEach(function (key) { return services.locationConfig[key] = notImplemented(key); });
	//# sourceMappingURL=coreservices.js.map

/***/ },
/* 8 */
/***/ function(module, exports) {

	var Queue = (function () {
	    function Queue(_items) {
	        if (_items === void 0) { _items = []; }
	        this._items = _items;
	    }
	    Queue.prototype.enqueue = function (item) {
	        this._items.push(item);
	        return item;
	    };
	    Queue.prototype.dequeue = function () {
	        if (this.size())
	            return this._items.splice(0, 1)[0];
	    };
	    Queue.prototype.clear = function () {
	        var current = this._items;
	        this._items = [];
	        return current;
	    };
	    Queue.prototype.size = function () {
	        return this._items.length;
	    };
	    Queue.prototype.remove = function (item) {
	        var idx = this._items.indexOf(item);
	        return idx > -1 && this._items.splice(idx, 1)[0];
	    };
	    Queue.prototype.peekTail = function () {
	        return this._items[this._items.length - 1];
	    };
	    Queue.prototype.peekHead = function () {
	        if (this.size())
	            return this._items[0];
	    };
	    return Queue;
	})();
	exports.Queue = Queue;
	//# sourceMappingURL=queue.js.map

/***/ },
/* 9 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var hof_1 = __webpack_require__(6);
	var predicates_1 = __webpack_require__(5);
	var resolvable_1 = __webpack_require__(10);
	var transition_1 = __webpack_require__(11);
	var rejectFactory_1 = __webpack_require__(26);
	function promiseToString(p) {
	    if (hof_1.is(rejectFactory_1.TransitionRejection)(p.reason))
	        return p.reason.toString();
	    return "Promise(" + JSON.stringify(p) + ")";
	}
	function functionToString(fn) {
	    var fnStr = common_1.fnToString(fn);
	    var namedFunctionMatch = fnStr.match(/^(function [^ ]+\([^)]*\))/);
	    return namedFunctionMatch ? namedFunctionMatch[1] : fnStr;
	}
	var uiViewString = function (viewData) {
	    return ("ui-view id#" + viewData.id + ", contextual name '" + viewData.name + "@" + viewData.creationContext + "', fqn: '" + viewData.fqn + "'");
	};
	var viewConfigString = function (viewConfig) {
	    return ("ViewConfig targeting ui-view: '" + viewConfig.uiViewName + "@" + viewConfig.uiViewContextAnchor + "', context: '" + viewConfig.context.name + "'");
	};
	function normalizedCat(input) {
	    return predicates_1.isNumber(input) ? Category[input] : Category[Category[input]];
	}
	function stringify(o) {
	    var format = hof_1.pattern([
	        [hof_1.not(predicates_1.isDefined), hof_1.val("undefined")],
	        [predicates_1.isNull, hof_1.val("null")],
	        [predicates_1.isPromise, promiseToString],
	        [hof_1.is(transition_1.Transition), hof_1.invoke("toString")],
	        [hof_1.is(resolvable_1.Resolvable), hof_1.invoke("toString")],
	        [predicates_1.isInjectable, functionToString],
	        [hof_1.val(true), common_1.identity]
	    ]);
	    return JSON.stringify(o, function (key, val) { return format(val); }).replace(/\\"/g, '"');
	}
	var Category;
	(function (Category) {
	    Category[Category["RESOLVE"] = 0] = "RESOLVE";
	    Category[Category["TRANSITION"] = 1] = "TRANSITION";
	    Category[Category["HOOK"] = 2] = "HOOK";
	    Category[Category["INVOKE"] = 3] = "INVOKE";
	    Category[Category["UIVIEW"] = 4] = "UIVIEW";
	    Category[Category["VIEWCONFIG"] = 5] = "VIEWCONFIG";
	})(Category || (Category = {}));
	var Trace = (function () {
	    function Trace() {
	        var _this = this;
	        this._enabled = {};
	        this.enable = function () {
	            var categories = [];
	            for (var _i = 0; _i < arguments.length; _i++) {
	                categories[_i - 0] = arguments[_i];
	            }
	            return _this._set(true, categories);
	        };
	        this.disable = function () {
	            var categories = [];
	            for (var _i = 0; _i < arguments.length; _i++) {
	                categories[_i - 0] = arguments[_i];
	            }
	            return _this._set(false, categories);
	        };
	        this.approximateDigests = 0;
	    }
	    Trace.prototype._set = function (enabled, categories) {
	        var _this = this;
	        if (!categories.length) {
	            categories = Object.keys(Category)
	                .filter(function (k) { return isNaN(parseInt(k, 10)); })
	                .map(function (key) { return Category[key]; });
	        }
	        categories.map(normalizedCat).forEach(function (category) { return _this._enabled[category] = enabled; });
	    };
	    Trace.prototype.enabled = function (category) {
	        return !!this._enabled[normalizedCat(category)];
	    };
	    Trace.prototype.traceTransitionStart = function (transition) {
	        if (!this.enabled(Category.TRANSITION))
	            return;
	        var tid = transition.$id, digest = this.approximateDigests, transitionStr = stringify(transition);
	        console.log("Transition #" + tid + " Digest #" + digest + ": Started  -> " + transitionStr);
	    };
	    Trace.prototype.traceTransitionIgnored = function (transition) {
	        if (!this.enabled(Category.TRANSITION))
	            return;
	        var tid = transition.$id, digest = this.approximateDigests, transitionStr = stringify(transition);
	        console.log("Transition #" + tid + " Digest #" + digest + ": Ignored  <> " + transitionStr);
	    };
	    Trace.prototype.traceHookInvocation = function (step, options) {
	        if (!this.enabled(Category.HOOK))
	            return;
	        var tid = hof_1.parse("transition.$id")(options), digest = this.approximateDigests, event = hof_1.parse("traceData.hookType")(options) || "internal", context = hof_1.parse("traceData.context.state.name")(options) || hof_1.parse("traceData.context")(options) || "unknown", name = functionToString(step.fn);
	        console.log("Transition #" + tid + " Digest #" + digest + ":   Hook -> " + event + " context: " + context + ", " + common_1.maxLength(200, name));
	    };
	    Trace.prototype.traceHookResult = function (hookResult, transitionResult, transitionOptions) {
	        if (!this.enabled(Category.HOOK))
	            return;
	        var tid = hof_1.parse("transition.$id")(transitionOptions), digest = this.approximateDigests, hookResultStr = stringify(hookResult), transitionResultStr = stringify(transitionResult);
	        console.log("Transition #" + tid + " Digest #" + digest + ":   <- Hook returned: " + common_1.maxLength(200, hookResultStr) + ", transition result: " + common_1.maxLength(200, transitionResultStr));
	    };
	    Trace.prototype.traceResolvePath = function (path, options) {
	        if (!this.enabled(Category.RESOLVE))
	            return;
	        var tid = hof_1.parse("transition.$id")(options), digest = this.approximateDigests, pathStr = path && path.toString(), policyStr = options && options.resolvePolicy;
	        console.log("Transition #" + tid + " Digest #" + digest + ":         Resolving " + pathStr + " (" + policyStr + ")");
	    };
	    Trace.prototype.traceResolvePathElement = function (pathElement, resolvablePromises, options) {
	        if (!this.enabled(Category.RESOLVE))
	            return;
	        if (!resolvablePromises.length)
	            return;
	        var tid = hof_1.parse("transition.$id")(options), digest = this.approximateDigests, resolvablePromisesStr = Object.keys(resolvablePromises).join(", "), pathElementStr = pathElement && pathElement.toString(), policyStr = options && options.resolvePolicy;
	        console.log("Transition #" + tid + " Digest #" + digest + ":         Resolve " + pathElementStr + " resolvables: [" + resolvablePromisesStr + "] (" + policyStr + ")");
	    };
	    Trace.prototype.traceResolveResolvable = function (resolvable, options) {
	        if (!this.enabled(Category.RESOLVE))
	            return;
	        var tid = hof_1.parse("transition.$id")(options), digest = this.approximateDigests, resolvableStr = resolvable && resolvable.toString();
	        console.log("Transition #" + tid + " Digest #" + digest + ":               Resolving -> " + resolvableStr);
	    };
	    Trace.prototype.traceResolvableResolved = function (resolvable, options) {
	        if (!this.enabled(Category.RESOLVE))
	            return;
	        var tid = hof_1.parse("transition.$id")(options), digest = this.approximateDigests, resolvableStr = resolvable && resolvable.toString(), result = stringify(resolvable.data);
	        console.log("Transition #" + tid + " Digest #" + digest + ":               <- Resolved  " + resolvableStr + " to: " + common_1.maxLength(200, result));
	    };
	    Trace.prototype.tracePathElementInvoke = function (node, fn, deps, options) {
	        if (!this.enabled(Category.INVOKE))
	            return;
	        var tid = hof_1.parse("transition.$id")(options), digest = this.approximateDigests, stateName = node && node.state && node.state.toString(), fnName = functionToString(fn);
	        console.log("Transition #" + tid + " Digest #" + digest + ":         Invoke " + options.when + ": context: " + stateName + " " + common_1.maxLength(200, fnName));
	    };
	    Trace.prototype.traceError = function (error, transition) {
	        if (!this.enabled(Category.TRANSITION))
	            return;
	        var tid = transition.$id, digest = this.approximateDigests, transitionStr = stringify(transition);
	        console.log("Transition #" + tid + " Digest #" + digest + ": <- Rejected " + transitionStr + ", reason: " + error);
	    };
	    Trace.prototype.traceSuccess = function (finalState, transition) {
	        if (!this.enabled(Category.TRANSITION))
	            return;
	        var tid = transition.$id, digest = this.approximateDigests, state = finalState.name, transitionStr = stringify(transition);
	        console.log("Transition #" + tid + " Digest #" + digest + ": <- Success  " + transitionStr + ", final state: " + state);
	    };
	    Trace.prototype.traceUiViewEvent = function (event, viewData, extra) {
	        if (extra === void 0) { extra = ""; }
	        if (!this.enabled(Category.UIVIEW))
	            return;
	        console.log("ui-view: " + common_1.padString(30, event) + " " + uiViewString(viewData) + extra);
	    };
	    Trace.prototype.traceUiViewConfigUpdated = function (viewData, context) {
	        if (!this.enabled(Category.UIVIEW))
	            return;
	        this.traceUiViewEvent("Updating", viewData, " with ViewConfig from context='" + context + "'");
	    };
	    Trace.prototype.traceUiViewScopeCreated = function (viewData, newScope) {
	        if (!this.enabled(Category.UIVIEW))
	            return;
	        this.traceUiViewEvent("Created scope for", viewData, ", scope #" + newScope.$id);
	    };
	    Trace.prototype.traceUiViewFill = function (viewData, html) {
	        if (!this.enabled(Category.UIVIEW))
	            return;
	        this.traceUiViewEvent("Fill", viewData, " with: " + common_1.maxLength(200, html));
	    };
	    Trace.prototype.traceViewServiceEvent = function (event, viewConfig) {
	        if (!this.enabled(Category.VIEWCONFIG))
	            return;
	        console.log("$view.ViewConfig: " + event + " " + viewConfigString(viewConfig));
	    };
	    Trace.prototype.traceViewServiceUiViewEvent = function (event, viewData) {
	        if (!this.enabled(Category.VIEWCONFIG))
	            return;
	        console.log("$view.ViewConfig: " + event + " " + uiViewString(viewData));
	    };
	    return Trace;
	})();
	var trace = new Trace();
	exports.trace = trace;
	//# sourceMappingURL=trace.js.map

/***/ },
/* 10 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var hof_1 = __webpack_require__(6);
	var predicates_1 = __webpack_require__(5);
	var coreservices_1 = __webpack_require__(7);
	var trace_1 = __webpack_require__(9);
	var Resolvable = (function () {
	    function Resolvable(name, resolveFn, preResolvedData) {
	        this.promise = undefined;
	        common_1.extend(this, { name: name, resolveFn: resolveFn, deps: coreservices_1.services.$injector.annotate(resolveFn), data: preResolvedData });
	    }
	    Resolvable.prototype.resolveResolvable = function (resolveContext, options) {
	        var _this = this;
	        if (options === void 0) { options = {}; }
	        var _a = this, name = _a.name, deps = _a.deps, resolveFn = _a.resolveFn;
	        trace_1.trace.traceResolveResolvable(this, options);
	        var deferred = coreservices_1.services.$q.defer();
	        this.promise = deferred.promise;
	        var ancestorsByName = resolveContext.getResolvables(null, { omitOwnLocals: [name] });
	        var depResolvables = common_1.pick(ancestorsByName, deps);
	        var depPromises = common_1.map(depResolvables, function (resolvable) { return resolvable.get(resolveContext, options); });
	        return coreservices_1.services.$q.all(depPromises).then(function (locals) {
	            try {
	                var result = coreservices_1.services.$injector.invoke(resolveFn, null, locals);
	                deferred.resolve(result);
	            }
	            catch (error) {
	                deferred.reject(error);
	            }
	            return _this.promise;
	        }).then(function (data) {
	            _this.data = data;
	            trace_1.trace.traceResolvableResolved(_this, options);
	            return _this.promise;
	        });
	    };
	    Resolvable.prototype.get = function (resolveContext, options) {
	        return this.promise || this.resolveResolvable(resolveContext, options);
	    };
	    Resolvable.prototype.toString = function () {
	        return "Resolvable(name: " + this.name + ", requires: [" + this.deps + "])";
	    };
	    Resolvable.makeResolvables = function (resolves) {
	        var invalid = common_1.filter(resolves, hof_1.not(predicates_1.isInjectable)), keys = Object.keys(invalid);
	        if (keys.length)
	            throw new Error("Invalid resolve key/value: " + keys[0] + "/" + invalid[keys[0]]);
	        return common_1.map(resolves, function (fn, name) { return new Resolvable(name, fn); });
	    };
	    return Resolvable;
	})();
	exports.Resolvable = Resolvable;
	//# sourceMappingURL=resolvable.js.map

/***/ },
/* 11 */
/***/ function(module, exports, __webpack_require__) {

	var trace_1 = __webpack_require__(9);
	var coreservices_1 = __webpack_require__(7);
	var common_1 = __webpack_require__(4);
	var predicates_1 = __webpack_require__(5);
	var hof_1 = __webpack_require__(6);
	var module_1 = __webpack_require__(12);
	var node_1 = __webpack_require__(38);
	var pathFactory_1 = __webpack_require__(36);
	var module_2 = __webpack_require__(15);
	var module_3 = __webpack_require__(19);
	var module_4 = __webpack_require__(39);
	var transitionCount = 0, REJECT = new module_1.RejectFactory();
	var stateSelf = hof_1.prop("self");
	var Transition = (function () {
	    function Transition(fromPath, targetState, $transitions) {
	        var _this = this;
	        this.$transitions = $transitions;
	        this._deferred = coreservices_1.services.$q.defer();
	        this.promise = this._deferred.promise;
	        this.treeChanges = function () { return _this._treeChanges; };
	        this.isActive = function () { return _this === _this._options.current(); };
	        if (!targetState.valid()) {
	            throw new Error(targetState.error());
	        }
	        module_1.HookRegistry.mixin(new module_1.HookRegistry(), this);
	        this._options = common_1.extend({ current: hof_1.val(this) }, targetState.options());
	        this.$id = transitionCount++;
	        var toPath = pathFactory_1.PathFactory.buildToPath(fromPath, targetState);
	        this._treeChanges = pathFactory_1.PathFactory.treeChanges(fromPath, toPath, this._options.reloadState);
	        pathFactory_1.PathFactory.bindTransitionResolve(this._treeChanges, this);
	    }
	    Transition.prototype.$from = function () {
	        return common_1.tail(this._treeChanges.from).state;
	    };
	    Transition.prototype.$to = function () {
	        return common_1.tail(this._treeChanges.to).state;
	    };
	    Transition.prototype.from = function () {
	        return this.$from().self;
	    };
	    Transition.prototype.to = function () {
	        return this.$to().self;
	    };
	    Transition.prototype.is = function (compare) {
	        if (compare instanceof Transition) {
	            return this.is({ to: compare.$to().name, from: compare.$from().name });
	        }
	        return !((compare.to && !module_1.matchState(this.$to(), compare.to)) ||
	            (compare.from && !module_1.matchState(this.$from(), compare.from)));
	    };
	    Transition.prototype.params = function (pathname) {
	        if (pathname === void 0) { pathname = "to"; }
	        return this._treeChanges[pathname].map(hof_1.prop("values")).reduce(common_1.mergeR, {});
	    };
	    Transition.prototype.resolves = function () {
	        return common_1.map(common_1.tail(this._treeChanges.to).resolveContext.getResolvables(), function (res) { return res.data; });
	    };
	    Transition.prototype.addResolves = function (resolves, state) {
	        if (state === void 0) { state = ""; }
	        var stateName = (typeof state === "string") ? state : state.name;
	        var topath = this._treeChanges.to;
	        var targetNode = common_1.find(topath, function (node) { return node.state.name === stateName; });
	        common_1.tail(topath).resolveContext.addResolvables(module_4.Resolvable.makeResolvables(resolves), targetNode.state);
	    };
	    Transition.prototype.previous = function () {
	        return this._options.previous || null;
	    };
	    Transition.prototype.options = function () {
	        return this._options;
	    };
	    Transition.prototype.entering = function () {
	        return common_1.map(this._treeChanges.entering, hof_1.prop('state')).map(stateSelf);
	    };
	    Transition.prototype.exiting = function () {
	        return common_1.map(this._treeChanges.exiting, hof_1.prop('state')).map(stateSelf).reverse();
	    };
	    Transition.prototype.retained = function () {
	        return common_1.map(this._treeChanges.retained, hof_1.prop('state')).map(stateSelf);
	    };
	    Transition.prototype.views = function (pathname, state) {
	        if (pathname === void 0) { pathname = "entering"; }
	        var path = this._treeChanges[pathname];
	        return state ? common_1.find(path, hof_1.propEq('state', state)).views : common_1.unnest(path.map(hof_1.prop("views")));
	    };
	    Transition.prototype.redirect = function (targetState) {
	        var newOptions = common_1.extend({}, this.options(), targetState.options(), { previous: this });
	        targetState = new module_2.TargetState(targetState.identifier(), targetState.$state(), targetState.params(), newOptions);
	        var redirectTo = new Transition(this._treeChanges.from, targetState, this.$transitions);
	        var redirectedPath = this.treeChanges().to;
	        var matching = node_1.Node.matching(redirectTo.treeChanges().to, redirectedPath);
	        var includeResolve = function (resolve, key) { return ['$stateParams', '$transition$'].indexOf(key) === -1; };
	        matching.forEach(function (node, idx) { return common_1.extend(node.resolves, common_1.filter(redirectedPath[idx].resolves, includeResolve)); });
	        return redirectTo;
	    };
	    Transition.prototype.ignored = function () {
	        var _a = this._treeChanges, to = _a.to, from = _a.from;
	        if (this._options.reload || common_1.tail(to).state !== common_1.tail(from).state)
	            return false;
	        var nodeSchemas = to.map(function (node) { return node.schema.filter(hof_1.not(hof_1.prop('dynamic'))); });
	        var _b = [to, from].map(function (path) { return path.map(hof_1.prop('values')); }), toValues = _b[0], fromValues = _b[1];
	        var tuples = common_1.arrayTuples(nodeSchemas, toValues, fromValues);
	        return tuples.map(function (_a) {
	            var schema = _a[0], toVals = _a[1], fromVals = _a[2];
	            return module_3.Param.equals(schema, toVals, fromVals);
	        }).reduce(common_1.allTrueR, true);
	    };
	    Transition.prototype.hookBuilder = function () {
	        return new module_1.HookBuilder(this.$transitions, this, {
	            transition: this,
	            current: this._options.current
	        });
	    };
	    Transition.prototype.run = function () {
	        var _this = this;
	        var hookBuilder = this.hookBuilder();
	        var runSynchronousHooks = module_1.TransitionHook.runSynchronousHooks;
	        var runSuccessHooks = function () { return runSynchronousHooks(hookBuilder.getOnSuccessHooks(), {}, true); };
	        var runErrorHooks = function ($error$) { return runSynchronousHooks(hookBuilder.getOnErrorHooks(), { $error$: $error$ }, true); };
	        this.promise.then(runSuccessHooks, runErrorHooks);
	        var syncResult = runSynchronousHooks(hookBuilder.getOnBeforeHooks());
	        if (module_1.TransitionHook.isRejection(syncResult)) {
	            var rejectReason = syncResult.reason;
	            this._deferred.reject(rejectReason);
	            return this.promise;
	        }
	        if (!this.valid()) {
	            var error = new Error(this.error());
	            this._deferred.reject(error);
	            return this.promise;
	        }
	        if (this.ignored()) {
	            trace_1.trace.traceTransitionIgnored(this);
	            var ignored = REJECT.ignored();
	            this._deferred.reject(ignored.reason);
	            return this.promise;
	        }
	        var resolve = function () {
	            _this._deferred.resolve(_this);
	            trace_1.trace.traceSuccess(_this.$to(), _this);
	        };
	        var reject = function (error) {
	            _this._deferred.reject(error);
	            trace_1.trace.traceError(error, _this);
	            return coreservices_1.services.$q.reject(error);
	        };
	        trace_1.trace.traceTransitionStart(this);
	        var chain = hookBuilder.asyncHooks().reduce(function (_chain, step) { return _chain.then(step.invokeStep); }, syncResult);
	        chain.then(resolve, reject);
	        return this.promise;
	    };
	    Transition.prototype.valid = function () {
	        return !this.error();
	    };
	    Transition.prototype.error = function () {
	        var state = this.$to();
	        if (state.self[common_1.abstractKey])
	            return "Cannot transition to abstract state '" + state.name + "'";
	        if (!module_3.Param.validates(state.parameters(), this.params()))
	            return "Param values not valid for state '" + state.name + "'";
	    };
	    Transition.prototype.toString = function () {
	        var fromStateOrName = this.from();
	        var toStateOrName = this.to();
	        var avoidEmptyHash = function (params) {
	            return (params["#"] !== null && params["#"] !== undefined) ? params : common_1.omit(params, "#");
	        };
	        var id = this.$id, from = predicates_1.isObject(fromStateOrName) ? fromStateOrName.name : fromStateOrName, fromParams = common_1.toJson(avoidEmptyHash(this._treeChanges.from.map(hof_1.prop('values')).reduce(common_1.mergeR, {}))), toValid = this.valid() ? "" : "(X) ", to = predicates_1.isObject(toStateOrName) ? toStateOrName.name : toStateOrName, toParams = common_1.toJson(avoidEmptyHash(this.params()));
	        return "Transition#" + id + "( '" + from + "'" + fromParams + " -> " + toValid + "'" + to + "'" + toParams + " )";
	    };
	    return Transition;
	})();
	exports.Transition = Transition;
	//# sourceMappingURL=transition.js.map

/***/ },
/* 12 */
/***/ function(module, exports, __webpack_require__) {

	function __export(m) {
	    for (var p in m) if (!exports.hasOwnProperty(p)) exports[p] = m[p];
	}
	__export(__webpack_require__(13));
	__export(__webpack_require__(14));
	__export(__webpack_require__(26));
	__export(__webpack_require__(11));
	__export(__webpack_require__(44));
	__export(__webpack_require__(43));
	//# sourceMappingURL=module.js.map

/***/ },
/* 13 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var predicates_1 = __webpack_require__(5);
	var module_1 = __webpack_require__(12);
	var HookBuilder = (function () {
	    function HookBuilder($transitions, transition, baseHookOptions) {
	        var _this = this;
	        this.$transitions = $transitions;
	        this.transition = transition;
	        this.baseHookOptions = baseHookOptions;
	        this.getOnBeforeHooks = function () { return _this._buildTransitionHooks("onBefore", {}, { async: false }); };
	        this.getOnStartHooks = function () { return _this._buildTransitionHooks("onStart"); };
	        this.getOnExitHooks = function () { return _this._buildNodeHooks("onExit", _this.treeChanges.exiting.reverse(), function (node) { return _this._toFrom({ from: node.state }); }); };
	        this.getOnRetainHooks = function () { return _this._buildNodeHooks("onRetain", _this.treeChanges.retained, function (node) { return _this._toFrom(); }); };
	        this.getOnEnterHooks = function () { return _this._buildNodeHooks("onEnter", _this.treeChanges.entering, function (node) { return _this._toFrom({ to: node.state }); }); };
	        this.getOnFinishHooks = function () { return _this._buildTransitionHooks("onFinish", { $treeChanges$: _this.treeChanges }); };
	        this.getOnSuccessHooks = function () { return _this._buildTransitionHooks("onSuccess", {}, { async: false, rejectIfSuperseded: false }); };
	        this.getOnErrorHooks = function () { return _this._buildTransitionHooks("onError", {}, { async: false, rejectIfSuperseded: false }); };
	        this.treeChanges = transition.treeChanges();
	        this.toState = common_1.tail(this.treeChanges.to).state;
	        this.fromState = common_1.tail(this.treeChanges.from).state;
	        this.transitionOptions = transition.options();
	    }
	    HookBuilder.prototype.asyncHooks = function () {
	        var onStartHooks = this.getOnStartHooks();
	        var onExitHooks = this.getOnExitHooks();
	        var onRetainHooks = this.getOnRetainHooks();
	        var onEnterHooks = this.getOnEnterHooks();
	        var onFinishHooks = this.getOnFinishHooks();
	        return common_1.flatten([onStartHooks, onExitHooks, onRetainHooks, onEnterHooks, onFinishHooks]).filter(common_1.identity);
	    };
	    HookBuilder.prototype._toFrom = function (toFromOverride) {
	        return common_1.extend({ to: this.toState, from: this.fromState }, toFromOverride);
	    };
	    HookBuilder.prototype._buildTransitionHooks = function (hookType, locals, options) {
	        var _this = this;
	        if (locals === void 0) { locals = {}; }
	        if (options === void 0) { options = {}; }
	        var context = this.treeChanges.to, node = common_1.tail(context);
	        options.traceData = { hookType: hookType, context: context };
	        var transitionHook = function (eventHook) { return _this.buildHook(node, eventHook.callback, locals, options); };
	        return this._matchingHooks(hookType, this._toFrom()).map(transitionHook);
	    };
	    HookBuilder.prototype._buildNodeHooks = function (hookType, path, toFromFn, locals, options) {
	        var _this = this;
	        if (locals === void 0) { locals = {}; }
	        if (options === void 0) { options = {}; }
	        var hooksForNode = function (node) {
	            var toFrom = toFromFn(node);
	            options.traceData = { hookType: hookType, context: node };
	            locals.$state$ = node.state;
	            var transitionHook = function (eventHook) { return _this.buildHook(node, eventHook.callback, locals, options); };
	            return _this._matchingHooks(hookType, toFrom).map(transitionHook);
	        };
	        return path.map(hooksForNode);
	    };
	    HookBuilder.prototype.buildHook = function (node, fn, locals, options) {
	        if (options === void 0) { options = {}; }
	        var _options = common_1.extend({}, this.baseHookOptions, options);
	        return new module_1.TransitionHook(fn, common_1.extend({}, locals), node.resolveContext, _options);
	    };
	    HookBuilder.prototype._matchingHooks = function (hookName, matchCriteria) {
	        var matchFilter = function (hook) { return hook.matches(matchCriteria.to, matchCriteria.from); };
	        var prioritySort = function (l, r) { return r.priority - l.priority; };
	        return [this.transition, this.$transitions]
	            .map(function (reg) { return reg.getHooks(hookName); })
	            .filter(common_1.assertPredicate(predicates_1.isArray, "broken event named: " + hookName))
	            .reduce(common_1.unnestR)
	            .filter(matchFilter)
	            .sort(prioritySort);
	    };
	    return HookBuilder;
	})();
	exports.HookBuilder = HookBuilder;
	//# sourceMappingURL=hookBuilder.js.map

/***/ },
/* 14 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var predicates_1 = __webpack_require__(5);
	var hof_1 = __webpack_require__(6);
	var module_1 = __webpack_require__(15);
	function matchState(state, matchCriteria) {
	    var toMatch = predicates_1.isString(matchCriteria) ? [matchCriteria] : matchCriteria;
	    function matchGlobs(_state) {
	        for (var i = 0; i < toMatch.length; i++) {
	            var glob = module_1.Glob.fromString(toMatch[i]);
	            if ((glob && glob.matches(_state.name)) || (!glob && toMatch[i] === _state.name)) {
	                return true;
	            }
	        }
	        return false;
	    }
	    var matchFn = (predicates_1.isFunction(toMatch) ? toMatch : matchGlobs);
	    return !!matchFn(state);
	}
	exports.matchState = matchState;
	var EventHook = (function () {
	    function EventHook(matchCriteria, callback, options) {
	        if (options === void 0) { options = {}; }
	        this.callback = callback;
	        this.matchCriteria = common_1.extend({ to: hof_1.val(true), from: hof_1.val(true) }, matchCriteria);
	        this.priority = options.priority || 0;
	    }
	    EventHook.prototype.matches = function (to, from) {
	        return matchState(to, this.matchCriteria.to) && matchState(from, this.matchCriteria.from);
	    };
	    return EventHook;
	})();
	exports.EventHook = EventHook;
	function makeHookRegistrationFn(hooks, name) {
	    return function (matchObject, callback, options) {
	        if (options === void 0) { options = {}; }
	        var eventHook = new EventHook(matchObject, callback, options);
	        hooks[name].push(eventHook);
	        return function deregisterEventHook() {
	            common_1.removeFrom(hooks[name])(eventHook);
	        };
	    };
	}
	var HookRegistry = (function () {
	    function HookRegistry() {
	        var _this = this;
	        this._transitionEvents = {
	            onBefore: [], onStart: [], onEnter: [], onRetain: [], onExit: [], onFinish: [], onSuccess: [], onError: []
	        };
	        this.getHooks = function (name) { return _this._transitionEvents[name]; };
	        this.onBefore = makeHookRegistrationFn(this._transitionEvents, "onBefore");
	        this.onStart = makeHookRegistrationFn(this._transitionEvents, "onStart");
	        this.onEnter = makeHookRegistrationFn(this._transitionEvents, "onEnter");
	        this.onRetain = makeHookRegistrationFn(this._transitionEvents, "onRetain");
	        this.onExit = makeHookRegistrationFn(this._transitionEvents, "onExit");
	        this.onFinish = makeHookRegistrationFn(this._transitionEvents, "onFinish");
	        this.onSuccess = makeHookRegistrationFn(this._transitionEvents, "onSuccess");
	        this.onError = makeHookRegistrationFn(this._transitionEvents, "onError");
	    }
	    HookRegistry.mixin = function (source, target) {
	        Object.keys(source._transitionEvents).concat(["getHooks"]).forEach(function (key) { return target[key] = source[key]; });
	    };
	    return HookRegistry;
	})();
	exports.HookRegistry = HookRegistry;
	//# sourceMappingURL=hookRegistry.js.map

/***/ },
/* 15 */
/***/ function(module, exports, __webpack_require__) {

	function __export(m) {
	    for (var p in m) if (!exports.hasOwnProperty(p)) exports[p] = m[p];
	}
	__export(__webpack_require__(16));
	__export(__webpack_require__(17));
	__export(__webpack_require__(18));
	__export(__webpack_require__(25));
	__export(__webpack_require__(32));
	__export(__webpack_require__(33));
	__export(__webpack_require__(34));
	__export(__webpack_require__(35));
	__export(__webpack_require__(27));
	//# sourceMappingURL=module.js.map

/***/ },
/* 16 */
/***/ function(module, exports) {

	var Glob = (function () {
	    function Glob(text) {
	        this.text = text;
	        this.glob = text.split('.');
	    }
	    Glob.prototype.matches = function (name) {
	        var segments = name.split('.');
	        for (var i = 0, l = this.glob.length; i < l; i++) {
	            if (this.glob[i] === '*')
	                segments[i] = '*';
	        }
	        if (this.glob[0] === '**') {
	            segments = segments.slice(segments.indexOf(this.glob[1]));
	            segments.unshift('**');
	        }
	        if (this.glob[this.glob.length - 1] === '**') {
	            segments.splice(segments.indexOf(this.glob[this.glob.length - 2]) + 1, Number.MAX_VALUE);
	            segments.push('**');
	        }
	        if (this.glob.length != segments.length)
	            return false;
	        return segments.join('') === this.glob.join('');
	    };
	    Glob.is = function (text) {
	        return text.indexOf('*') > -1;
	    };
	    Glob.fromString = function (text) {
	        if (!this.is(text))
	            return null;
	        return new Glob(text);
	    };
	    return Glob;
	})();
	exports.Glob = Glob;
	//# sourceMappingURL=glob.js.map

/***/ },
/* 17 */
/***/ function(module, exports, __webpack_require__) {

	var predicates_1 = __webpack_require__(5);
	var common_1 = __webpack_require__(4);
	var StateProvider = (function () {
	    function StateProvider(stateRegistry) {
	        this.stateRegistry = stateRegistry;
	        this.invalidCallbacks = [];
	        common_1.bindFunctions(StateProvider.prototype, this, this);
	    }
	    StateProvider.prototype.decorator = function (name, func) {
	        return this.stateRegistry.decorator(name, func) || this;
	    };
	    StateProvider.prototype.state = function (name, definition) {
	        if (predicates_1.isObject(name)) {
	            definition = name;
	        }
	        else {
	            definition.name = name;
	        }
	        this.stateRegistry.register(definition);
	        return this;
	    };
	    StateProvider.prototype.onInvalid = function (callback) {
	        this.invalidCallbacks.push(callback);
	    };
	    return StateProvider;
	})();
	exports.StateProvider = StateProvider;
	//# sourceMappingURL=state.js.map

/***/ },
/* 18 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var predicates_1 = __webpack_require__(5);
	var hof_1 = __webpack_require__(6);
	var module_1 = __webpack_require__(19);
	var parseUrl = function (url) {
	    if (!predicates_1.isString(url))
	        return false;
	    var root = url.charAt(0) === '^';
	    return { val: root ? url.substring(1) : url, root: root };
	};
	var StateBuilder = (function () {
	    function StateBuilder(matcher, $urlMatcherFactoryProvider) {
	        this.matcher = matcher;
	        var self = this;
	        var isRoot = function (state) { return state.name === ""; };
	        var root = function () { return matcher.find(""); };
	        this.builders = {
	            parent: [function (state) {
	                    if (isRoot(state))
	                        return null;
	                    return matcher.find(self.parentName(state)) || root();
	                }],
	            data: [function (state) {
	                    if (state.parent && state.parent.data) {
	                        state.data = state.self.data = common_1.inherit(state.parent.data, state.data);
	                    }
	                    return state.data;
	                }],
	            url: [function (state) {
	                    var stateDec = state;
	                    var parsed = parseUrl(stateDec.url), parent = state.parent;
	                    var url = !parsed ? stateDec.url : $urlMatcherFactoryProvider.compile(parsed.val, {
	                        params: state.params || {},
	                        paramMap: function (paramConfig, isSearch) {
	                            if (stateDec.reloadOnSearch === false && isSearch)
	                                paramConfig = common_1.extend(paramConfig || {}, { dynamic: true });
	                            return paramConfig;
	                        }
	                    });
	                    if (!url)
	                        return null;
	                    if (!$urlMatcherFactoryProvider.isMatcher(url))
	                        throw new Error("Invalid url '" + url + "' in state '" + state + "'");
	                    return (parsed && parsed.root) ? url : ((parent && parent.navigable) || root()).url.append(url);
	                }],
	            navigable: [function (state) {
	                    return !isRoot(state) && state.url ? state : (state.parent ? state.parent.navigable : null);
	                }],
	            params: [function (state) {
	                    var makeConfigParam = function (config, id) { return module_1.Param.fromConfig(id, null, config); };
	                    var urlParams = (state.url && state.url.parameters({ inherit: false })) || [];
	                    var nonUrlParams = common_1.values(common_1.map(common_1.omit(state.params || {}, urlParams.map(hof_1.prop('id'))), makeConfigParam));
	                    return urlParams.concat(nonUrlParams).map(function (p) { return [p.id, p]; }).reduce(common_1.applyPairs, {});
	                }],
	            views: [function (state) {
	                    var views = {}, tplKeys = ['templateProvider', 'templateUrl', 'template', 'notify', 'async'], ctrlKeys = ['controller', 'controllerProvider', 'controllerAs'];
	                    var allKeys = tplKeys.concat(ctrlKeys);
	                    common_1.forEach(state.views || { "$default": common_1.pick(state, allKeys) }, function (config, name) {
	                        name = name || "$default";
	                        common_1.forEach(ctrlKeys, function (key) {
	                            if (state[key] && !config[key])
	                                config[key] = state[key];
	                        });
	                        if (Object.keys(config).length > 0)
	                            views[name] = config;
	                    });
	                    return views;
	                }],
	            path: [function (state) {
	                    return state.parent ? state.parent.path.concat(state) : [state];
	                }],
	            includes: [function (state) {
	                    var includes = state.parent ? common_1.extend({}, state.parent.includes) : {};
	                    includes[state.name] = true;
	                    return includes;
	                }]
	        };
	    }
	    StateBuilder.prototype.builder = function (name, fn) {
	        var builders = this.builders;
	        var array = builders[name] || [];
	        if (predicates_1.isString(name) && !predicates_1.isDefined(fn))
	            return array.length > 1 ? array : array[0];
	        if (!predicates_1.isString(name) || !predicates_1.isFunction(fn))
	            return;
	        builders[name] = array;
	        builders[name].push(fn);
	        return function () { return builders[name].splice(builders[name].indexOf(fn, 1)) && null; };
	    };
	    StateBuilder.prototype.build = function (state) {
	        var _a = this, matcher = _a.matcher, builders = _a.builders;
	        var parent = this.parentName(state);
	        if (parent && !matcher.find(parent))
	            return null;
	        for (var key in builders) {
	            if (!builders.hasOwnProperty(key))
	                continue;
	            var chain = builders[key].reduce(function (parentFn, step) { return function (_state) { return step(_state, parentFn); }; }, common_1.noop);
	            state[key] = chain(state);
	        }
	        return state;
	    };
	    StateBuilder.prototype.parentName = function (state) {
	        var name = state.name || "";
	        if (name.indexOf('.') !== -1)
	            return name.substring(0, name.lastIndexOf('.'));
	        if (!state.parent)
	            return "";
	        return predicates_1.isString(state.parent) ? state.parent : state.parent.name;
	    };
	    StateBuilder.prototype.name = function (state) {
	        var name = state.name;
	        if (name.indexOf('.') !== -1 || !state.parent)
	            return name;
	        var parentName = predicates_1.isString(state.parent) ? state.parent : state.parent.name;
	        return parentName ? parentName + "." + name : name;
	    };
	    return StateBuilder;
	})();
	exports.StateBuilder = StateBuilder;
	//# sourceMappingURL=stateBuilder.js.map

/***/ },
/* 19 */
/***/ function(module, exports, __webpack_require__) {

	function __export(m) {
	    for (var p in m) if (!exports.hasOwnProperty(p)) exports[p] = m[p];
	}
	__export(__webpack_require__(20));
	__export(__webpack_require__(23));
	__export(__webpack_require__(24));
	__export(__webpack_require__(22));
	//# sourceMappingURL=module.js.map

/***/ },
/* 20 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var hof_1 = __webpack_require__(6);
	var predicates_1 = __webpack_require__(5);
	var coreservices_1 = __webpack_require__(7);
	var urlMatcherConfig_1 = __webpack_require__(21);
	var type_1 = __webpack_require__(22);
	var paramTypes_1 = __webpack_require__(23);
	var hasOwn = Object.prototype.hasOwnProperty;
	var isShorthand = function (cfg) { return ["value", "type", "squash", "array", "dynamic"].filter(hasOwn.bind(cfg || {})).length === 0; };
	(function (DefType) {
	    DefType[DefType["PATH"] = 0] = "PATH";
	    DefType[DefType["SEARCH"] = 1] = "SEARCH";
	    DefType[DefType["CONFIG"] = 2] = "CONFIG";
	})(exports.DefType || (exports.DefType = {}));
	var DefType = exports.DefType;
	function unwrapShorthand(cfg) {
	    cfg = isShorthand(cfg) && { value: cfg } || cfg;
	    return common_1.extend(cfg, {
	        $$fn: predicates_1.isInjectable(cfg.value) ? cfg.value : function () { return cfg.value; }
	    });
	}
	function getType(cfg, urlType, location, id) {
	    if (cfg.type && urlType && urlType.name !== 'string')
	        throw new Error("Param '" + id + "' has two type configurations.");
	    if (cfg.type && urlType && urlType.name === 'string' && paramTypes_1.paramTypes.type(cfg.type))
	        return paramTypes_1.paramTypes.type(cfg.type);
	    if (urlType)
	        return urlType;
	    if (!cfg.type)
	        return (location === DefType.CONFIG ? paramTypes_1.paramTypes.type("any") : paramTypes_1.paramTypes.type("string"));
	    return cfg.type instanceof type_1.Type ? cfg.type : paramTypes_1.paramTypes.type(cfg.type);
	}
	function getSquashPolicy(config, isOptional) {
	    var squash = config.squash;
	    if (!isOptional || squash === false)
	        return false;
	    if (!predicates_1.isDefined(squash) || squash == null)
	        return urlMatcherConfig_1.matcherConfig.defaultSquashPolicy();
	    if (squash === true || predicates_1.isString(squash))
	        return squash;
	    throw new Error("Invalid squash policy: '" + squash + "'. Valid policies: false, true, or arbitrary string");
	}
	function getReplace(config, arrayMode, isOptional, squash) {
	    var replace, configuredKeys, defaultPolicy = [
	        { from: "", to: (isOptional || arrayMode ? undefined : "") },
	        { from: null, to: (isOptional || arrayMode ? undefined : "") }
	    ];
	    replace = predicates_1.isArray(config.replace) ? config.replace : [];
	    if (predicates_1.isString(squash))
	        replace.push({ from: squash, to: undefined });
	    configuredKeys = common_1.map(replace, hof_1.prop("from"));
	    return common_1.filter(defaultPolicy, function (item) { return configuredKeys.indexOf(item.from) === -1; }).concat(replace);
	}
	var Param = (function () {
	    function Param(id, type, config, location) {
	        config = unwrapShorthand(config);
	        type = getType(config, type, location, id);
	        var arrayMode = getArrayMode();
	        type = arrayMode ? type.$asArray(arrayMode, location === DefType.SEARCH) : type;
	        var isOptional = config.value !== undefined;
	        var dynamic = config.dynamic === true;
	        var squash = getSquashPolicy(config, isOptional);
	        var replace = getReplace(config, arrayMode, isOptional, squash);
	        function getArrayMode() {
	            var arrayDefaults = { array: (location === DefType.SEARCH ? "auto" : false) };
	            var arrayParamNomenclature = id.match(/\[\]$/) ? { array: true } : {};
	            return common_1.extend(arrayDefaults, arrayParamNomenclature, config).array;
	        }
	        common_1.extend(this, { id: id, type: type, location: location, squash: squash, replace: replace, isOptional: isOptional, dynamic: dynamic, config: config, array: arrayMode });
	    }
	    Param.prototype.isDefaultValue = function (value) {
	        return this.isOptional && this.type.equals(this.value(), value);
	    };
	    Param.prototype.value = function (value) {
	        var _this = this;
	        var $$getDefaultValue = function () {
	            if (!coreservices_1.services.$injector)
	                throw new Error("Injectable functions cannot be called at configuration time");
	            var defaultValue = coreservices_1.services.$injector.invoke(_this.config.$$fn);
	            if (defaultValue !== null && defaultValue !== undefined && !_this.type.is(defaultValue))
	                throw new Error("Default value (" + defaultValue + ") for parameter '" + _this.id + "' is not an instance of Type (" + _this.type.name + ")");
	            return defaultValue;
	        };
	        var $replace = function (val) {
	            var replacement = common_1.map(common_1.filter(_this.replace, hof_1.propEq('from', val)), hof_1.prop("to"));
	            return replacement.length ? replacement[0] : val;
	        };
	        value = $replace(value);
	        return !predicates_1.isDefined(value) ? $$getDefaultValue() : this.type.$normalize(value);
	    };
	    Param.prototype.isSearch = function () {
	        return this.location === DefType.SEARCH;
	    };
	    Param.prototype.validates = function (value) {
	        if ((!predicates_1.isDefined(value) || value === null) && this.isOptional)
	            return true;
	        var normalized = this.type.$normalize(value);
	        if (!this.type.is(normalized))
	            return false;
	        var encoded = this.type.encode(normalized);
	        return !(predicates_1.isString(encoded) && !this.type.pattern.exec(encoded));
	    };
	    Param.prototype.toString = function () {
	        return "{Param:" + this.id + " " + this.type + " squash: '" + this.squash + "' optional: " + this.isOptional + "}";
	    };
	    Param.fromConfig = function (id, type, config) {
	        return new Param(id, type, config, DefType.CONFIG);
	    };
	    Param.fromPath = function (id, type, config) {
	        return new Param(id, type, config, DefType.PATH);
	    };
	    Param.fromSearch = function (id, type, config) {
	        return new Param(id, type, config, DefType.SEARCH);
	    };
	    Param.values = function (params, values) {
	        values = values || {};
	        return params.map(function (param) { return [param.id, param.value(values[param.id])]; }).reduce(common_1.applyPairs, {});
	    };
	    Param.equals = function (params, values1, values2) {
	        values1 = values1 || {};
	        values2 = values2 || {};
	        return params.map(function (param) { return param.type.equals(values1[param.id], values2[param.id]); }).indexOf(false) === -1;
	    };
	    Param.validates = function (params, values) {
	        values = values || {};
	        return params.map(function (param) { return param.validates(values[param.id]); }).indexOf(false) === -1;
	    };
	    return Param;
	})();
	exports.Param = Param;
	//# sourceMappingURL=param.js.map

/***/ },
/* 21 */
/***/ function(module, exports, __webpack_require__) {

	var predicates_1 = __webpack_require__(5);
	var MatcherConfig = (function () {
	    function MatcherConfig() {
	        this._isCaseInsensitive = false;
	        this._isStrictMode = true;
	        this._defaultSquashPolicy = false;
	    }
	    MatcherConfig.prototype.caseInsensitive = function (value) {
	        return this._isCaseInsensitive = predicates_1.isDefined(value) ? value : this._isCaseInsensitive;
	    };
	    MatcherConfig.prototype.strictMode = function (value) {
	        return this._isStrictMode = predicates_1.isDefined(value) ? value : this._isStrictMode;
	    };
	    MatcherConfig.prototype.defaultSquashPolicy = function (value) {
	        if (predicates_1.isDefined(value) && value !== true && value !== false && !predicates_1.isString(value))
	            throw new Error("Invalid squash policy: " + value + ". Valid policies: false, true, arbitrary-string");
	        return this._defaultSquashPolicy = predicates_1.isDefined(value) ? value : this._defaultSquashPolicy;
	    };
	    return MatcherConfig;
	})();
	exports.matcherConfig = new MatcherConfig();
	//# sourceMappingURL=urlMatcherConfig.js.map

/***/ },
/* 22 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var predicates_1 = __webpack_require__(5);
	function ArrayType(type, mode) {
	    var _this = this;
	    function arrayWrap(val) { return predicates_1.isArray(val) ? val : (predicates_1.isDefined(val) ? [val] : []); }
	    function arrayUnwrap(val) {
	        switch (val.length) {
	            case 0: return undefined;
	            case 1: return mode === "auto" ? val[0] : val;
	            default: return val;
	        }
	    }
	    function arrayHandler(callback, allTruthyMode) {
	        return function handleArray(val) {
	            if (predicates_1.isArray(val) && val.length === 0)
	                return val;
	            var arr = arrayWrap(val);
	            var result = common_1.map(arr, callback);
	            return (allTruthyMode === true) ? common_1.filter(result, function (x) { return !x; }).length === 0 : arrayUnwrap(result);
	        };
	    }
	    function arrayEqualsHandler(callback) {
	        return function handleArray(val1, val2) {
	            var left = arrayWrap(val1), right = arrayWrap(val2);
	            if (left.length !== right.length)
	                return false;
	            for (var i = 0; i < left.length; i++) {
	                if (!callback(left[i], right[i]))
	                    return false;
	            }
	            return true;
	        };
	    }
	    ['encode', 'decode', 'equals', '$normalize'].map(function (name) {
	        _this[name] = (name === 'equals' ? arrayEqualsHandler : arrayHandler)(type[name].bind(type));
	    });
	    common_1.extend(this, {
	        name: type.name,
	        pattern: type.pattern,
	        is: arrayHandler(type.is.bind(type), true),
	        $arrayMode: mode
	    });
	}
	var Type = (function () {
	    function Type(def) {
	        this.pattern = /.*/;
	        common_1.extend(this, def);
	    }
	    Type.prototype.is = function (val, key) { return true; };
	    Type.prototype.encode = function (val, key) { return val; };
	    Type.prototype.decode = function (val, key) { return val; };
	    Type.prototype.equals = function (a, b) { return a == b; };
	    Type.prototype.$subPattern = function () {
	        var sub = this.pattern.toString();
	        return sub.substr(1, sub.length - 2);
	    };
	    Type.prototype.toString = function () {
	        return "{Type:" + this.name + "}";
	    };
	    Type.prototype.$normalize = function (val) {
	        return this.is(val) ? val : this.decode(val);
	    };
	    Type.prototype.$asArray = function (mode, isSearch) {
	        if (!mode)
	            return this;
	        if (mode === "auto" && !isSearch)
	            throw new Error("'auto' array mode is for query parameters only");
	        return new ArrayType(this, mode);
	    };
	    return Type;
	})();
	exports.Type = Type;
	//# sourceMappingURL=type.js.map

/***/ },
/* 23 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var predicates_1 = __webpack_require__(5);
	var hof_1 = __webpack_require__(6);
	var coreservices_1 = __webpack_require__(7);
	var type_1 = __webpack_require__(22);
	function valToString(val) { return val != null ? val.toString().replace(/~/g, "~~").replace(/\//g, "~2F") : val; }
	function valFromString(val) { return val != null ? val.toString().replace(/~2F/g, "/").replace(/~~/g, "~") : val; }
	var ParamTypes = (function () {
	    function ParamTypes() {
	        this.enqueue = true;
	        this.typeQueue = [];
	        this.defaultTypes = {
	            "hash": {
	                encode: valToString,
	                decode: valFromString,
	                is: hof_1.is(String),
	                pattern: /.*/,
	                equals: hof_1.val(true)
	            },
	            "string": {
	                encode: valToString,
	                decode: valFromString,
	                is: hof_1.is(String),
	                pattern: /[^/]*/
	            },
	            "int": {
	                encode: valToString,
	                decode: function (val) { return parseInt(val, 10); },
	                is: function (val) { return predicates_1.isDefined(val) && this.decode(val.toString()) === val; },
	                pattern: /-?\d+/
	            },
	            "bool": {
	                encode: function (val) { return val && 1 || 0; },
	                decode: function (val) { return parseInt(val, 10) !== 0; },
	                is: hof_1.is(Boolean),
	                pattern: /0|1/
	            },
	            "date": {
	                encode: function (val) {
	                    return !this.is(val) ? undefined : [
	                        val.getFullYear(),
	                        ('0' + (val.getMonth() + 1)).slice(-2),
	                        ('0' + val.getDate()).slice(-2)
	                    ].join("-");
	                },
	                decode: function (val) {
	                    if (this.is(val))
	                        return val;
	                    var match = this.capture.exec(val);
	                    return match ? new Date(match[1], match[2] - 1, match[3]) : undefined;
	                },
	                is: function (val) { return val instanceof Date && !isNaN(val.valueOf()); },
	                equals: function (a, b) { return this.is(a) && this.is(b) && a.toISOString() === b.toISOString(); },
	                pattern: /[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[1-2][0-9]|3[0-1])/,
	                capture: /([0-9]{4})-(0[1-9]|1[0-2])-(0[1-9]|[1-2][0-9]|3[0-1])/
	            },
	            "json": {
	                encode: common_1.toJson,
	                decode: common_1.fromJson,
	                is: hof_1.is(Object),
	                equals: common_1.equals,
	                pattern: /[^/]*/
	            },
	            "any": {
	                encode: common_1.identity,
	                decode: common_1.identity,
	                equals: common_1.equals,
	                pattern: /.*/
	            }
	        };
	        var makeType = function (definition, name) { return new type_1.Type(common_1.extend({ name: name }, definition)); };
	        this.types = common_1.inherit(common_1.map(this.defaultTypes, makeType), {});
	    }
	    ParamTypes.prototype.type = function (name, definition, definitionFn) {
	        if (!predicates_1.isDefined(definition))
	            return this.types[name];
	        if (this.types.hasOwnProperty(name))
	            throw new Error("A type named '" + name + "' has already been defined.");
	        this.types[name] = new type_1.Type(common_1.extend({ name: name }, definition));
	        if (definitionFn) {
	            this.typeQueue.push({ name: name, def: definitionFn });
	            if (!this.enqueue)
	                this._flushTypeQueue();
	        }
	        return this;
	    };
	    ParamTypes.prototype._flushTypeQueue = function () {
	        while (this.typeQueue.length) {
	            var type = this.typeQueue.shift();
	            if (type.pattern)
	                throw new Error("You cannot override a type's .pattern at runtime.");
	            common_1.extend(this.types[type.name], coreservices_1.services.$injector.invoke(type.def));
	        }
	    };
	    return ParamTypes;
	})();
	exports.paramTypes = new ParamTypes();
	//# sourceMappingURL=paramTypes.js.map

/***/ },
/* 24 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var StateParams = (function () {
	    function StateParams(params) {
	        if (params === void 0) { params = {}; }
	        common_1.extend(this, params);
	    }
	    StateParams.prototype.$digest = function () { };
	    StateParams.prototype.$inherit = function (newParams, $current, $to) { };
	    StateParams.prototype.$set = function (params, url) { };
	    StateParams.prototype.$sync = function () { };
	    StateParams.prototype.$off = function () { };
	    StateParams.prototype.$raw = function () { };
	    StateParams.prototype.$localize = function (state, params) { };
	    StateParams.prototype.$observe = function (key, fn) { };
	    return StateParams;
	})();
	exports.StateParams = StateParams;
	function stateParamsFactory() {
	    var observers = {}, current = {};
	    function unhook(key, func) {
	        return function () {
	            common_1.forEach(key.split(" "), function (k) { return observers[k].splice(observers[k].indexOf(func), 1); });
	        };
	    }
	    function observeChange(key, val) {
	        if (!observers[key] || !observers[key].length)
	            return;
	        common_1.forEach(observers[key], function (func) { return func(val); });
	    }
	    StateParams.prototype.$digest = function () {
	        var _this = this;
	        common_1.forEach(this, function (val, key) {
	            if (val === current[key] || !_this.hasOwnProperty(key))
	                return;
	            current[key] = val;
	            observeChange(key, val);
	        });
	    };
	    StateParams.prototype.$inherit = function (newParams, $current, $to) {
	        var parents = common_1.ancestors($current, $to), parentParams, inherited = {}, inheritList = [];
	        for (var i in parents) {
	            if (!parents[i] || !parents[i].params)
	                continue;
	            parentParams = Object.keys(parents[i].params);
	            if (!parentParams.length)
	                continue;
	            for (var j in parentParams) {
	                if (inheritList.indexOf(parentParams[j]) >= 0)
	                    continue;
	                inheritList.push(parentParams[j]);
	                inherited[parentParams[j]] = this[parentParams[j]];
	            }
	        }
	        return common_1.extend({}, inherited, newParams);
	    };
	    StateParams.prototype.$set = function (params, url) {
	        var _this = this;
	        var hasChanged = false, abort = false;
	        if (url) {
	            common_1.forEach(params, function (val, key) {
	                if ((url.parameter(key) || {}).dynamic !== true)
	                    abort = true;
	            });
	        }
	        if (abort)
	            return false;
	        common_1.forEach(params, function (val, key) {
	            if (val !== _this[key]) {
	                _this[key] = val;
	                observeChange(key);
	                hasChanged = true;
	            }
	        });
	        this.$sync();
	        return hasChanged;
	    };
	    StateParams.prototype.$sync = function () {
	        common_1.copy(this, current);
	        return this;
	    };
	    StateParams.prototype.$off = function () {
	        observers = {};
	        return this;
	    };
	    StateParams.prototype.$raw = function () {
	        return common_1.omit(this, Object.keys(this).filter(StateParams.prototype.hasOwnProperty.bind(StateParams.prototype)));
	    };
	    StateParams.prototype.$localize = function (state, params) {
	        return new StateParams(common_1.pick(params || this, Object.keys(state.params)));
	    };
	    StateParams.prototype.$observe = function (key, fn) {
	        common_1.forEach(key.split(" "), function (k) { return (observers[k] || (observers[k] = [])).push(fn); });
	        return unhook(key, fn);
	    };
	    return new StateParams();
	}
	exports.stateParamsFactory = stateParamsFactory;
	//# sourceMappingURL=stateParams.js.map

/***/ },
/* 25 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var hof_1 = __webpack_require__(6);
	var param_1 = __webpack_require__(20);
	var rejectFactory_1 = __webpack_require__(26);
	var targetState_1 = __webpack_require__(27);
	var viewHooks_1 = __webpack_require__(28);
	var enterExitHooks_1 = __webpack_require__(29);
	var resolveHooks_1 = __webpack_require__(30);
	var TransitionManager = (function () {
	    function TransitionManager(transition, $transitions, $urlRouter, $view, $state, $stateParams, $q, activeTransQ, changeHistory) {
	        this.transition = transition;
	        this.$transitions = $transitions;
	        this.$urlRouter = $urlRouter;
	        this.$view = $view;
	        this.$state = $state;
	        this.$stateParams = $stateParams;
	        this.$q = $q;
	        this.activeTransQ = activeTransQ;
	        this.changeHistory = changeHistory;
	        this.viewHooks = new viewHooks_1.ViewHooks(transition, $view);
	        this.enterExitHooks = new enterExitHooks_1.EnterExitHooks(transition);
	        this.resolveHooks = new resolveHooks_1.ResolveHooks(transition);
	        this.treeChanges = transition.treeChanges();
	        this.registerUpdateGlobalState();
	        this.viewHooks.registerHooks();
	        this.enterExitHooks.registerHooks();
	        this.resolveHooks.registerHooks();
	    }
	    TransitionManager.prototype.runTransition = function () {
	        var _this = this;
	        this.activeTransQ.clear();
	        this.activeTransQ.enqueue(this.transition);
	        this.$state.transition = this.transition;
	        var promise = this.transition.run()
	            .then(function (trans) { return trans.to(); })
	            .catch(function (error) { return _this.transRejected(error); });
	        var always = function () {
	            _this.activeTransQ.remove(_this.transition);
	            if (_this.$state.transition === _this.transition)
	                _this.transition = null;
	        };
	        promise.then(always, always);
	        return promise;
	    };
	    TransitionManager.prototype.registerUpdateGlobalState = function () {
	        this.transition.onFinish({}, this.updateGlobalState.bind(this), { priority: -10000 });
	    };
	    TransitionManager.prototype.updateGlobalState = function () {
	        var _a = this, treeChanges = _a.treeChanges, transition = _a.transition, $state = _a.$state, changeHistory = _a.changeHistory;
	        $state.$current = transition.$to();
	        $state.current = $state.$current.self;
	        changeHistory.enqueue(treeChanges);
	        this.updateStateParams();
	    };
	    TransitionManager.prototype.transRejected = function (error) {
	        var _a = this, transition = _a.transition, $state = _a.$state, $stateParams = _a.$stateParams, $q = _a.$q;
	        if (error instanceof rejectFactory_1.TransitionRejection) {
	            if (error.type === rejectFactory_1.RejectType.IGNORED) {
	                var dynamic = $state.$current.parameters().filter(hof_1.prop('dynamic'));
	                if (!param_1.Param.equals(dynamic, $stateParams, transition.params())) {
	                    this.updateStateParams();
	                }
	                return $state.current;
	            }
	            if (error.type === rejectFactory_1.RejectType.SUPERSEDED && error.redirected && error.detail instanceof targetState_1.TargetState) {
	                return this._redirectMgr(transition.redirect(error.detail)).runTransition();
	            }
	        }
	        this.$transitions.defaultErrorHandler()(error);
	        return $q.reject(error);
	    };
	    TransitionManager.prototype.updateStateParams = function () {
	        var _a = this, transition = _a.transition, $urlRouter = _a.$urlRouter, $state = _a.$state, $stateParams = _a.$stateParams;
	        var options = transition.options();
	        $state.params = transition.params();
	        common_1.copy($state.params, $stateParams);
	        $stateParams.$sync().$off();
	        if (options.location && $state.$current.navigable) {
	            $urlRouter.push($state.$current.navigable.url, $stateParams, { replace: options.location === 'replace' });
	        }
	        $urlRouter.update(true);
	    };
	    TransitionManager.prototype._redirectMgr = function (redirect) {
	        var _a = this, $transitions = _a.$transitions, $urlRouter = _a.$urlRouter, $view = _a.$view, $state = _a.$state, $stateParams = _a.$stateParams, $q = _a.$q, activeTransQ = _a.activeTransQ, changeHistory = _a.changeHistory;
	        return new TransitionManager(redirect, $transitions, $urlRouter, $view, $state, $stateParams, $q, activeTransQ, changeHistory);
	    };
	    return TransitionManager;
	})();
	exports.TransitionManager = TransitionManager;
	//# sourceMappingURL=transitionManager.js.map

/***/ },
/* 26 */
/***/ function(module, exports, __webpack_require__) {

	"use strict";
	var common_1 = __webpack_require__(4);
	var coreservices_1 = __webpack_require__(7);
	(function (RejectType) {
	    RejectType[RejectType["SUPERSEDED"] = 2] = "SUPERSEDED";
	    RejectType[RejectType["ABORTED"] = 3] = "ABORTED";
	    RejectType[RejectType["INVALID"] = 4] = "INVALID";
	    RejectType[RejectType["IGNORED"] = 5] = "IGNORED";
	})(exports.RejectType || (exports.RejectType = {}));
	var RejectType = exports.RejectType;
	var TransitionRejection = (function () {
	    function TransitionRejection(type, message, detail) {
	        common_1.extend(this, {
	            type: type,
	            message: message,
	            detail: detail
	        });
	    }
	    TransitionRejection.prototype.toString = function () {
	        var detailString = function (d) { return d && d.toString !== Object.prototype.toString ? d.toString() : JSON.stringify(d); };
	        var type = this.type, message = this.message, detail = detailString(this.detail);
	        return "TransitionRejection(type: " + type + ", message: " + message + ", detail: " + detail + ")";
	    };
	    return TransitionRejection;
	})();
	exports.TransitionRejection = TransitionRejection;
	var RejectFactory = (function () {
	    function RejectFactory() {
	    }
	    RejectFactory.prototype.superseded = function (detail, options) {
	        var message = "The transition has been superseded by a different transition (see detail).";
	        var reason = new TransitionRejection(RejectType.SUPERSEDED, message, detail);
	        if (options && options.redirected) {
	            reason.redirected = true;
	        }
	        return common_1.extend(coreservices_1.services.$q.reject(reason), { reason: reason });
	    };
	    RejectFactory.prototype.redirected = function (detail) {
	        return this.superseded(detail, { redirected: true });
	    };
	    RejectFactory.prototype.invalid = function (detail) {
	        var message = "This transition is invalid (see detail)";
	        var reason = new TransitionRejection(RejectType.INVALID, message, detail);
	        return common_1.extend(coreservices_1.services.$q.reject(reason), { reason: reason });
	    };
	    RejectFactory.prototype.ignored = function (detail) {
	        var message = "The transition was ignored.";
	        var reason = new TransitionRejection(RejectType.IGNORED, message, detail);
	        return common_1.extend(coreservices_1.services.$q.reject(reason), { reason: reason });
	    };
	    RejectFactory.prototype.aborted = function (detail) {
	        var message = "The transition has been aborted.";
	        var reason = new TransitionRejection(RejectType.ABORTED, message, detail);
	        return common_1.extend(coreservices_1.services.$q.reject(reason), { reason: reason });
	    };
	    return RejectFactory;
	})();
	exports.RejectFactory = RejectFactory;
	//# sourceMappingURL=rejectFactory.js.map

/***/ },
/* 27 */
/***/ function(module, exports) {

	var TargetState = (function () {
	    function TargetState(_identifier, _definition, _params, _options) {
	        if (_params === void 0) { _params = {}; }
	        if (_options === void 0) { _options = {}; }
	        this._identifier = _identifier;
	        this._definition = _definition;
	        this._options = _options;
	        this._params = _params || {};
	    }
	    TargetState.prototype.name = function () {
	        return this._definition && this._definition.name || this._identifier;
	    };
	    TargetState.prototype.identifier = function () {
	        return this._identifier;
	    };
	    TargetState.prototype.params = function () {
	        return this._params;
	    };
	    TargetState.prototype.$state = function () {
	        return this._definition;
	    };
	    TargetState.prototype.state = function () {
	        return this._definition && this._definition.self;
	    };
	    TargetState.prototype.options = function () {
	        return this._options;
	    };
	    TargetState.prototype.exists = function () {
	        return !!(this._definition && this._definition.self);
	    };
	    TargetState.prototype.valid = function () {
	        return !this.error();
	    };
	    TargetState.prototype.error = function () {
	        var base = this.options().relative;
	        if (!this._definition && !!base) {
	            var stateName = base.name ? base.name : base;
	            return "Could not resolve '" + this.name() + "' from state '" + stateName + "'";
	        }
	        if (!this._definition)
	            return "No such state '" + this.name() + "'";
	        if (!this._definition.self)
	            return "State '" + this.name() + "' has an invalid definition";
	    };
	    return TargetState;
	})();
	exports.TargetState = TargetState;
	//# sourceMappingURL=targetState.js.map

/***/ },
/* 28 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var hof_1 = __webpack_require__(6);
	var coreservices_1 = __webpack_require__(7);
	var ViewHooks = (function () {
	    function ViewHooks(transition, $view) {
	        this.transition = transition;
	        this.$view = $view;
	        this.treeChanges = transition.treeChanges();
	        this.enteringViews = transition.views("entering");
	        this.exitingViews = transition.views("exiting");
	    }
	    ViewHooks.prototype.loadAllEnteringViews = function () {
	        var _this = this;
	        var loadView = function (vc) {
	            var resolveInjector = common_1.find(_this.treeChanges.to, hof_1.propEq('state', vc.context)).resolveInjector;
	            return _this.$view.load(vc, resolveInjector);
	        };
	        return coreservices_1.services.$q.all(this.enteringViews.map(loadView)).then(common_1.noop);
	    };
	    ViewHooks.prototype.updateViews = function () {
	        var $view = this.$view;
	        this.exitingViews.forEach(function (viewConfig) { return $view.reset(viewConfig); });
	        this.enteringViews.forEach(function (viewConfig) { return $view.registerStateViewConfig(viewConfig); });
	        $view.sync();
	    };
	    ViewHooks.prototype.registerHooks = function () {
	        if (this.enteringViews.length) {
	            this.transition.onStart({}, this.loadAllEnteringViews.bind(this));
	        }
	        if (this.exitingViews.length || this.enteringViews.length)
	            this.transition.onSuccess({}, this.updateViews.bind(this));
	    };
	    return ViewHooks;
	})();
	exports.ViewHooks = ViewHooks;
	//# sourceMappingURL=viewHooks.js.map

/***/ },
/* 29 */
/***/ function(module, exports) {

	var EnterExitHooks = (function () {
	    function EnterExitHooks(transition) {
	        this.transition = transition;
	    }
	    EnterExitHooks.prototype.registerHooks = function () {
	        this.registerOnEnterHooks();
	        this.registerOnRetainHooks();
	        this.registerOnExitHooks();
	    };
	    EnterExitHooks.prototype.registerOnEnterHooks = function () {
	        var _this = this;
	        var onEnterRegistration = function (state) { return _this.transition.onEnter({ to: state.name }, state.onEnter); };
	        this.transition.entering().filter(function (state) { return !!state.onEnter; }).forEach(onEnterRegistration);
	    };
	    EnterExitHooks.prototype.registerOnRetainHooks = function () {
	        var _this = this;
	        var onRetainRegistration = function (state) { return _this.transition.onRetain({}, state.onRetain); };
	        this.transition.retained().filter(function (state) { return !!state.onRetain; }).forEach(onRetainRegistration);
	    };
	    EnterExitHooks.prototype.registerOnExitHooks = function () {
	        var _this = this;
	        var onExitRegistration = function (state) { return _this.transition.onExit({ from: state.name }, state.onExit); };
	        this.transition.exiting().filter(function (state) { return !!state.onExit; }).forEach(onExitRegistration);
	    };
	    return EnterExitHooks;
	})();
	exports.EnterExitHooks = EnterExitHooks;
	//# sourceMappingURL=enterExitHooks.js.map

/***/ },
/* 30 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var hof_1 = __webpack_require__(6);
	var interface_1 = __webpack_require__(31);
	var LAZY = interface_1.ResolvePolicy[interface_1.ResolvePolicy.LAZY];
	var EAGER = interface_1.ResolvePolicy[interface_1.ResolvePolicy.EAGER];
	var ResolveHooks = (function () {
	    function ResolveHooks(transition) {
	        this.transition = transition;
	    }
	    ResolveHooks.prototype.registerHooks = function () {
	        var treeChanges = this.transition.treeChanges();
	        $eagerResolvePath.$inject = ['$transition$'];
	        function $eagerResolvePath($transition$) {
	            return common_1.tail(treeChanges.to).resolveContext.resolvePath(common_1.extend({ transition: $transition$ }, { resolvePolicy: EAGER }));
	        }
	        $lazyResolveEnteringState.$inject = ['$state$', '$transition$'];
	        function $lazyResolveEnteringState($state$, $transition$) {
	            var node = common_1.find(treeChanges.entering, hof_1.propEq('state', $state$));
	            return node.resolveContext.resolvePathElement(node.state, common_1.extend({ transition: $transition$ }, { resolvePolicy: LAZY }));
	        }
	        this.transition.onStart({}, $eagerResolvePath, { priority: 1000 });
	        this.transition.onEnter({}, $lazyResolveEnteringState, { priority: 1000 });
	    };
	    return ResolveHooks;
	})();
	exports.ResolveHooks = ResolveHooks;
	//# sourceMappingURL=resolveHooks.js.map

/***/ },
/* 31 */
/***/ function(module, exports) {

	(function (ResolvePolicy) {
	    ResolvePolicy[ResolvePolicy["JIT"] = 0] = "JIT";
	    ResolvePolicy[ResolvePolicy["LAZY"] = 1] = "LAZY";
	    ResolvePolicy[ResolvePolicy["EAGER"] = 2] = "EAGER";
	})(exports.ResolvePolicy || (exports.ResolvePolicy = {}));
	var ResolvePolicy = exports.ResolvePolicy;
	//# sourceMappingURL=interface.js.map

/***/ },
/* 32 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var hof_1 = __webpack_require__(6);
	var State = (function () {
	    function State(config) {
	        common_1.extend(this, config);
	    }
	    State.prototype.is = function (ref) {
	        return this === ref || this.self === ref || this.fqn() === ref;
	    };
	    State.prototype.fqn = function () {
	        if (!this.parent || !(this.parent instanceof this.constructor))
	            return this.name;
	        var name = this.parent.fqn();
	        return name ? name + "." + this.name : this.name;
	    };
	    State.prototype.root = function () {
	        return this.parent && this.parent.root() || this;
	    };
	    State.prototype.parameters = function (opts) {
	        opts = common_1.defaults(opts, { inherit: true });
	        var inherited = opts.inherit && this.parent && this.parent.parameters() || [];
	        return inherited.concat(common_1.values(this.params));
	    };
	    State.prototype.parameter = function (id, opts) {
	        if (opts === void 0) { opts = {}; }
	        return (this.url && this.url.parameter(id, opts) ||
	            common_1.find(common_1.values(this.params), hof_1.propEq('id', id)) ||
	            opts.inherit && this.parent && this.parent.parameter(id));
	    };
	    State.prototype.toString = function () {
	        return this.fqn();
	    };
	    return State;
	})();
	exports.State = State;
	//# sourceMappingURL=stateObject.js.map

/***/ },
/* 33 */
/***/ function(module, exports, __webpack_require__) {

	var predicates_1 = __webpack_require__(5);
	var StateMatcher = (function () {
	    function StateMatcher(_states) {
	        this._states = _states;
	    }
	    StateMatcher.prototype.isRelative = function (stateName) {
	        stateName = stateName || "";
	        return stateName.indexOf(".") === 0 || stateName.indexOf("^") === 0;
	    };
	    StateMatcher.prototype.find = function (stateOrName, base) {
	        if (!stateOrName && stateOrName !== "")
	            return undefined;
	        var isStr = predicates_1.isString(stateOrName);
	        var name = isStr ? stateOrName : stateOrName.name;
	        if (this.isRelative(name))
	            name = this.resolvePath(name, base);
	        var state = this._states[name];
	        if (state && (isStr || (!isStr && (state === stateOrName || state.self === stateOrName)))) {
	            return state;
	        }
	        return undefined;
	    };
	    StateMatcher.prototype.resolvePath = function (name, base) {
	        if (!base)
	            throw new Error("No reference point given for path '" + name + "'");
	        var baseState = this.find(base);
	        var splitName = name.split("."), i = 0, pathLength = splitName.length, current = baseState;
	        for (; i < pathLength; i++) {
	            if (splitName[i] === "" && i === 0) {
	                current = baseState;
	                continue;
	            }
	            if (splitName[i] === "^") {
	                if (!current.parent)
	                    throw new Error("Path '" + name + "' not valid for state '" + baseState.name + "'");
	                current = current.parent;
	                continue;
	            }
	            break;
	        }
	        var relName = splitName.slice(i).join(".");
	        return current.name + (current.name && relName ? "." : "") + relName;
	    };
	    return StateMatcher;
	})();
	exports.StateMatcher = StateMatcher;
	//# sourceMappingURL=stateMatcher.js.map

/***/ },
/* 34 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var predicates_1 = __webpack_require__(5);
	var module_1 = __webpack_require__(15);
	var StateQueueManager = (function () {
	    function StateQueueManager(states, builder, $urlRouterProvider) {
	        this.states = states;
	        this.builder = builder;
	        this.$urlRouterProvider = $urlRouterProvider;
	        this.queue = [];
	    }
	    StateQueueManager.prototype.register = function (config) {
	        var _a = this, states = _a.states, queue = _a.queue, $state = _a.$state;
	        var state = common_1.inherit(new module_1.State(), common_1.extend({}, config, {
	            self: config,
	            resolve: config.resolve || {},
	            toString: function () { return config.name; }
	        }));
	        if (!predicates_1.isString(state.name))
	            throw new Error("State must have a valid name");
	        if (states.hasOwnProperty(state.name) || common_1.pluck(queue, 'name').indexOf(state.name) !== -1)
	            throw new Error("State '" + state.name + "' is already defined");
	        queue.push(state);
	        if (this.$state) {
	            this.flush($state);
	        }
	        return state;
	    };
	    StateQueueManager.prototype.flush = function ($state) {
	        var _a = this, queue = _a.queue, states = _a.states, builder = _a.builder;
	        var result, state, orphans = [], orphanIdx, previousQueueLength = {};
	        while (queue.length > 0) {
	            state = queue.shift();
	            result = builder.build(state);
	            orphanIdx = orphans.indexOf(state);
	            if (result) {
	                if (states.hasOwnProperty(state.name))
	                    throw new Error("State '" + name + "' is already defined");
	                states[state.name] = state;
	                this.attachRoute($state, state);
	                if (orphanIdx >= 0)
	                    orphans.splice(orphanIdx, 1);
	                continue;
	            }
	            var prev = previousQueueLength[state.name];
	            previousQueueLength[state.name] = queue.length;
	            if (orphanIdx >= 0 && prev === queue.length) {
	                throw new Error("Cannot register orphaned state '" + state.name + "'");
	            }
	            else if (orphanIdx < 0) {
	                orphans.push(state);
	            }
	            queue.push(state);
	        }
	        return states;
	    };
	    StateQueueManager.prototype.autoFlush = function ($state) {
	        this.$state = $state;
	        this.flush($state);
	    };
	    StateQueueManager.prototype.attachRoute = function ($state, state) {
	        var $urlRouterProvider = this.$urlRouterProvider;
	        if (state[common_1.abstractKey] || !state.url)
	            return;
	        $urlRouterProvider.when(state.url, ['$match', '$stateParams', function ($match, $stateParams) {
	                if ($state.$current.navigable !== state || !common_1.equalForKeys($match, $stateParams)) {
	                    $state.transitionTo(state, $match, { inherit: true, location: false });
	                }
	            }]);
	    };
	    return StateQueueManager;
	})();
	exports.StateQueueManager = StateQueueManager;
	//# sourceMappingURL=stateQueueManager.js.map

/***/ },
/* 35 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var predicates_1 = __webpack_require__(5);
	var queue_1 = __webpack_require__(8);
	var coreservices_1 = __webpack_require__(7);
	var pathFactory_1 = __webpack_require__(36);
	var node_1 = __webpack_require__(38);
	var stateParams_1 = __webpack_require__(24);
	var transitionService_1 = __webpack_require__(43);
	var rejectFactory_1 = __webpack_require__(26);
	var targetState_1 = __webpack_require__(27);
	var transitionManager_1 = __webpack_require__(25);
	var param_1 = __webpack_require__(20);
	var glob_1 = __webpack_require__(16);
	var common_2 = __webpack_require__(4);
	var common_3 = __webpack_require__(4);
	var StateService = (function () {
	    function StateService($view, $stateParams, $urlRouter, $transitions, stateRegistry, stateProvider) {
	        this.$view = $view;
	        this.$stateParams = $stateParams;
	        this.$urlRouter = $urlRouter;
	        this.$transitions = $transitions;
	        this.stateRegistry = stateRegistry;
	        this.stateProvider = stateProvider;
	        this.transQueue = new queue_1.Queue();
	        this.treeChangesQueue = new queue_1.Queue();
	        this.rejectFactory = new rejectFactory_1.RejectFactory();
	        this.params = new stateParams_1.StateParams();
	        common_3.bindFunctions(StateService.prototype, this, this);
	        var root = stateRegistry.root();
	        common_1.extend(this, {
	            params: new stateParams_1.StateParams(),
	            current: root.self,
	            $current: root,
	            transition: null
	        });
	    }
	    StateService.prototype._handleInvalidTargetState = function (fromPath, $to$) {
	        var _this = this;
	        var latestThing = function () { return _this.transQueue.peekTail() || _this.treeChangesQueue.peekTail(); };
	        var latest = latestThing();
	        var $from$ = pathFactory_1.PathFactory.makeTargetState(fromPath);
	        var callbackQueue = new queue_1.Queue([].concat(this.stateProvider.invalidCallbacks));
	        var rejectFactory = this.rejectFactory;
	        var $q = coreservices_1.services.$q, $injector = coreservices_1.services.$injector;
	        var invokeCallback = function (callback) { return $q.when($injector.invoke(callback, null, { $to$: $to$, $from$: $from$ })); };
	        var checkForRedirect = function (result) {
	            if (!(result instanceof targetState_1.TargetState)) {
	                return;
	            }
	            var target = result;
	            target = _this.target(target.identifier(), target.params(), target.options());
	            if (!target.valid())
	                return rejectFactory.invalid(target.error());
	            if (latestThing() !== latest)
	                return rejectFactory.superseded();
	            return _this.transitionTo(target.identifier(), target.params(), target.options());
	        };
	        function invokeNextCallback() {
	            var nextCallback = callbackQueue.dequeue();
	            if (nextCallback === undefined)
	                return rejectFactory.invalid($to$.error());
	            return invokeCallback(nextCallback).then(checkForRedirect).then(function (result) { return result || invokeNextCallback(); });
	        }
	        return invokeNextCallback();
	    };
	    StateService.prototype.reload = function (reloadState) {
	        return this.transitionTo(this.current, this.$stateParams, {
	            reload: predicates_1.isDefined(reloadState) ? reloadState : true,
	            inherit: false,
	            notify: false
	        });
	    };
	    ;
	    StateService.prototype.go = function (to, params, options) {
	        var defautGoOpts = { relative: this.$current, inherit: true };
	        var transOpts = common_1.defaults(options, defautGoOpts, transitionService_1.defaultTransOpts);
	        return this.transitionTo(to, params, transOpts);
	    };
	    ;
	    StateService.prototype.target = function (identifier, params, options) {
	        if (options === void 0) { options = {}; }
	        var stateDefinition = this.stateRegistry.matcher.find(identifier, options.relative);
	        return new targetState_1.TargetState(identifier, stateDefinition, params, options);
	    };
	    ;
	    StateService.prototype.transitionTo = function (to, toParams, options) {
	        var _this = this;
	        if (toParams === void 0) { toParams = {}; }
	        if (options === void 0) { options = {}; }
	        var _a = this, transQueue = _a.transQueue, treeChangesQueue = _a.treeChangesQueue;
	        options = common_1.defaults(options, transitionService_1.defaultTransOpts);
	        options = common_1.extend(options, { current: transQueue.peekTail.bind(transQueue) });
	        if (predicates_1.isObject(options.reload) && !options.reload.name)
	            throw new Error('Invalid reload state object');
	        options.reloadState = options.reload === true ? this.$current.path[0] : this.stateRegistry.matcher.find(options.reload, options.relative);
	        if (options.reload && !options.reloadState)
	            throw new Error("No such reload state '" + (predicates_1.isString(options.reload) ? options.reload : options.reload.name) + "'");
	        var ref = this.target(to, toParams, options);
	        var latestTreeChanges = treeChangesQueue.peekTail();
	        var rootPath = function () { return pathFactory_1.PathFactory.bindTransNodesToPath([new node_1.Node(_this.stateRegistry.root(), {})]); };
	        var currentPath = latestTreeChanges ? latestTreeChanges.to : rootPath();
	        if (!ref.exists())
	            return this._handleInvalidTargetState(currentPath, ref);
	        if (!ref.valid())
	            return coreservices_1.services.$q.reject(ref.error());
	        var transition = this.$transitions.create(currentPath, ref);
	        var tMgr = new transitionManager_1.TransitionManager(transition, this.$transitions, this.$urlRouter, this.$view, this, this.$stateParams, coreservices_1.services.$q, transQueue, treeChangesQueue);
	        var transitionPromise = tMgr.runTransition();
	        return common_1.extend(transitionPromise, { transition: transition });
	    };
	    ;
	    StateService.prototype.is = function (stateOrName, params, options) {
	        options = common_1.defaults(options, { relative: this.$current });
	        var state = this.stateRegistry.matcher.find(stateOrName, options.relative);
	        if (!predicates_1.isDefined(state))
	            return undefined;
	        if (this.$current !== state)
	            return false;
	        return predicates_1.isDefined(params) && params !== null ? param_1.Param.equals(state.parameters(), this.$stateParams, params) : true;
	    };
	    ;
	    StateService.prototype.includes = function (stateOrName, params, options) {
	        options = common_1.defaults(options, { relative: this.$current });
	        var glob = predicates_1.isString(stateOrName) && glob_1.Glob.fromString(stateOrName);
	        if (glob) {
	            if (!glob.matches(this.$current.name))
	                return false;
	            stateOrName = this.$current.name;
	        }
	        var state = this.stateRegistry.matcher.find(stateOrName, options.relative), include = this.$current.includes;
	        if (!predicates_1.isDefined(state))
	            return undefined;
	        if (!predicates_1.isDefined(include[state.name]))
	            return false;
	        return params ? common_2.equalForKeys(param_1.Param.values(state.parameters(), params), this.$stateParams, Object.keys(params)) : true;
	    };
	    ;
	    StateService.prototype.href = function (stateOrName, params, options) {
	        var defaultHrefOpts = {
	            lossy: true,
	            inherit: true,
	            absolute: false,
	            relative: this.$current
	        };
	        options = common_1.defaults(options, defaultHrefOpts);
	        var state = this.stateRegistry.matcher.find(stateOrName, options.relative);
	        if (!predicates_1.isDefined(state))
	            return null;
	        if (options.inherit)
	            params = this.$stateParams.$inherit(params || {}, this.$current, state);
	        var nav = (state && options.lossy) ? state.navigable : state;
	        if (!nav || nav.url === undefined || nav.url === null) {
	            return null;
	        }
	        return this.$urlRouter.href(nav.url, param_1.Param.values(state.parameters(), params), {
	            absolute: options.absolute
	        });
	    };
	    ;
	    StateService.prototype.get = function (stateOrName, base) {
	        return this.stateRegistry.get.apply(this.stateRegistry, arguments);
	    };
	    return StateService;
	})();
	exports.StateService = StateService;
	//# sourceMappingURL=stateService.js.map

/***/ },
/* 36 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var hof_1 = __webpack_require__(6);
	var module_1 = __webpack_require__(15);
	var module_2 = __webpack_require__(37);
	var module_3 = __webpack_require__(39);
	var PathFactory = (function () {
	    function PathFactory() {
	    }
	    PathFactory.makeTargetState = function (path) {
	        var state = common_1.tail(path).state;
	        return new module_1.TargetState(state, state, path.map(hof_1.prop("values")).reduce(common_1.mergeR, {}));
	    };
	    PathFactory.buildToPath = function (fromPath, targetState) {
	        var toParams = targetState.params();
	        var toParamsNodeFn = PathFactory.makeParamsNode(toParams);
	        var toPath = targetState.$state().path.map(toParamsNodeFn);
	        if (targetState.options().inherit)
	            toPath = PathFactory.inheritParams(fromPath, toPath, Object.keys(toParams));
	        return toPath;
	    };
	    PathFactory.inheritParams = function (fromPath, toPath, toKeys) {
	        if (toKeys === void 0) { toKeys = []; }
	        function nodeParamVals(path, state) {
	            var node = common_1.find(path, hof_1.propEq('state', state));
	            return common_1.extend({}, node && node.values);
	        }
	        var makeInheritedParamsNode = hof_1.curry(function (_fromPath, _toKeys, toNode) {
	            var toParamVals = common_1.extend({}, toNode && toNode.values);
	            var incomingParamVals = common_1.pick(toParamVals, _toKeys);
	            toParamVals = common_1.omit(toParamVals, _toKeys);
	            var fromParamVals = nodeParamVals(_fromPath, toNode.state) || {};
	            var ownParamVals = common_1.extend(toParamVals, fromParamVals, incomingParamVals);
	            return new module_2.Node(toNode.state, ownParamVals);
	        });
	        return toPath.map(makeInheritedParamsNode(fromPath, toKeys));
	    };
	    PathFactory.bindTransNodesToPath = function (resolvePath) {
	        var resolveContext = new module_3.ResolveContext(resolvePath);
	        resolvePath.forEach(function (node) {
	            node.resolveContext = resolveContext.isolateRootTo(node.state);
	            node.resolveInjector = new module_3.ResolveInjector(node.resolveContext, node.state);
	            node.resolves.$stateParams = new module_3.Resolvable("$stateParams", function () { return node.values; }, node.values);
	        });
	        return resolvePath;
	    };
	    PathFactory.treeChanges = function (fromPath, toPath, reloadState) {
	        var keep = 0, max = Math.min(fromPath.length, toPath.length);
	        var staticParams = function (state) { return state.parameters({ inherit: false }).filter(hof_1.not(hof_1.prop('dynamic'))).map(hof_1.prop('id')); };
	        var nodesMatch = function (node1, node2) { return node1.equals(node2, staticParams(node1.state)); };
	        while (keep < max && fromPath[keep].state !== reloadState && nodesMatch(fromPath[keep], toPath[keep])) {
	            keep++;
	        }
	        function applyToParams(retainedNode, idx) {
	            return module_2.Node.clone(retainedNode, { values: toPath[idx].values });
	        }
	        var from, retained, exiting, entering, to;
	        var retainedWithToParams, enteringResolvePath, toResolvePath;
	        from = fromPath;
	        retained = from.slice(0, keep);
	        exiting = from.slice(keep);
	        retainedWithToParams = retained.map(applyToParams);
	        enteringResolvePath = toPath.slice(keep);
	        toResolvePath = (retainedWithToParams).concat(enteringResolvePath);
	        to = PathFactory.bindTransNodesToPath(toResolvePath);
	        entering = to.slice(keep);
	        return { from: from, to: to, retained: retained, exiting: exiting, entering: entering };
	    };
	    PathFactory.bindTransitionResolve = function (treeChanges, transition) {
	        var rootNode = treeChanges.to[0];
	        rootNode.resolves.$transition$ = new module_3.Resolvable('$transition$', function () { return transition; }, transition);
	    };
	    PathFactory.makeParamsNode = hof_1.curry(function (params, state) { return new module_2.Node(state, params); });
	    return PathFactory;
	})();
	exports.PathFactory = PathFactory;
	//# sourceMappingURL=pathFactory.js.map

/***/ },
/* 37 */
/***/ function(module, exports, __webpack_require__) {

	function __export(m) {
	    for (var p in m) if (!exports.hasOwnProperty(p)) exports[p] = m[p];
	}
	__export(__webpack_require__(38));
	__export(__webpack_require__(36));
	//# sourceMappingURL=module.js.map

/***/ },
/* 38 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var hof_1 = __webpack_require__(6);
	var module_1 = __webpack_require__(39);
	var view_1 = __webpack_require__(42);
	var Node = (function () {
	    function Node(state, params, resolves) {
	        if (params === void 0) { params = {}; }
	        if (resolves === void 0) { resolves = {}; }
	        this.state = state;
	        this.schema = state.parameters({ inherit: false });
	        var getParamVal = function (paramDef) { return [paramDef.id, paramDef.value(params[paramDef.id])]; };
	        this.values = this.schema.reduce(function (memo, pDef) { return common_1.applyPairs(memo, getParamVal(pDef)); }, {});
	        this.resolves = common_1.extend(common_1.map(state.resolve, function (fn, name) { return new module_1.Resolvable(name, fn); }), resolves);
	        var makeViewConfig = function (viewDeclarationObj, rawViewName) {
	            return new view_1.ViewConfig({ rawViewName: rawViewName, viewDeclarationObj: viewDeclarationObj, context: state, params: params });
	        };
	        this.views = common_1.values(common_1.map(state.views, makeViewConfig));
	    }
	    Node.prototype.parameter = function (name) {
	        return common_1.find(this.schema, hof_1.propEq("id", name));
	    };
	    Node.prototype.equals = function (node, keys) {
	        var _this = this;
	        if (keys === void 0) { keys = this.schema.map(hof_1.prop('id')); }
	        var paramValsEq = function (key) { return _this.parameter(key).type.equals(_this.values[key], node.values[key]); };
	        return this.state === node.state && keys.map(paramValsEq).reduce(common_1.allTrueR, true);
	    };
	    Node.clone = function (node, update) {
	        if (update === void 0) { update = {}; }
	        return new Node(node.state, (update.values || node.values), (update.resolves || node.resolves));
	    };
	    Node.matching = function (first, second) {
	        var matchedCount = first.reduce(function (prev, node, i) {
	            return prev === i && i < second.length && node.state === second[i].state ? i + 1 : prev;
	        }, 0);
	        return first.slice(0, matchedCount);
	    };
	    return Node;
	})();
	exports.Node = Node;
	//# sourceMappingURL=node.js.map

/***/ },
/* 39 */
/***/ function(module, exports, __webpack_require__) {

	function __export(m) {
	    for (var p in m) if (!exports.hasOwnProperty(p)) exports[p] = m[p];
	}
	__export(__webpack_require__(10));
	__export(__webpack_require__(40));
	__export(__webpack_require__(41));
	//# sourceMappingURL=module.js.map

/***/ },
/* 40 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var hof_1 = __webpack_require__(6);
	var predicates_1 = __webpack_require__(5);
	var trace_1 = __webpack_require__(9);
	var coreservices_1 = __webpack_require__(7);
	var interface_1 = __webpack_require__(31);
	var common_2 = __webpack_require__(4);
	var defaultResolvePolicy = interface_1.ResolvePolicy[interface_1.ResolvePolicy.LAZY];
	var ResolveContext = (function () {
	    function ResolveContext(_path) {
	        this._path = _path;
	        common_1.extend(this, {
	            _nodeFor: function (state) {
	                return common_1.find(this._path, hof_1.propEq('state', state));
	            },
	            _pathTo: function (state) {
	                var node = this._nodeFor(state);
	                var elementIdx = this._path.indexOf(node);
	                if (elementIdx === -1)
	                    throw new Error("This path does not contain the state");
	                return this._path.slice(0, elementIdx + 1);
	            }
	        });
	    }
	    ResolveContext.prototype.getResolvables = function (state, options) {
	        options = common_1.defaults(options, { omitOwnLocals: [] });
	        var path = (state ? this._pathTo(state) : this._path);
	        var last = common_1.tail(path);
	        return path.reduce(function (memo, node) {
	            var omitProps = (node === last) ? options.omitOwnLocals : [];
	            var filteredResolvables = common_1.omit(node.resolves, omitProps);
	            return common_1.extend(memo, filteredResolvables);
	        }, {});
	    };
	    ResolveContext.prototype.getResolvablesForFn = function (fn) {
	        var deps = coreservices_1.services.$injector.annotate(fn);
	        return common_1.pick(this.getResolvables(), deps);
	    };
	    ResolveContext.prototype.isolateRootTo = function (state) {
	        return new ResolveContext(this._pathTo(state));
	    };
	    ResolveContext.prototype.addResolvables = function (resolvables, state) {
	        common_1.extend(this._nodeFor(state).resolves, resolvables);
	    };
	    ResolveContext.prototype.getOwnResolvables = function (state) {
	        return common_1.extend({}, this._nodeFor(state).resolves);
	    };
	    ResolveContext.prototype.resolvePath = function (options) {
	        var _this = this;
	        if (options === void 0) { options = {}; }
	        trace_1.trace.traceResolvePath(this._path, options);
	        var promiseForNode = function (node) { return _this.resolvePathElement(node.state, options); };
	        return coreservices_1.services.$q.all(common_1.map(this._path, promiseForNode)).then(function (all) { return all.reduce(common_2.mergeR, {}); });
	    };
	    ResolveContext.prototype.resolvePathElement = function (state, options) {
	        var _this = this;
	        if (options === void 0) { options = {}; }
	        var policy = options && options.resolvePolicy;
	        var policyOrdinal = interface_1.ResolvePolicy[policy || defaultResolvePolicy];
	        var resolvables = this.getOwnResolvables(state);
	        var matchesRequestedPolicy = function (resolvable) { return getPolicy(state.resolvePolicy, resolvable) >= policyOrdinal; };
	        var matchingResolves = common_1.filter(resolvables, matchesRequestedPolicy);
	        var getResolvePromise = function (resolvable) { return resolvable.get(_this.isolateRootTo(state), options); };
	        var resolvablePromises = common_1.map(matchingResolves, getResolvePromise);
	        trace_1.trace.traceResolvePathElement(this, matchingResolves, options);
	        return coreservices_1.services.$q.all(resolvablePromises);
	    };
	    ResolveContext.prototype.invokeLater = function (fn, locals, options) {
	        var _this = this;
	        if (locals === void 0) { locals = {}; }
	        if (options === void 0) { options = {}; }
	        var resolvables = this.getResolvablesForFn(fn);
	        trace_1.trace.tracePathElementInvoke(common_1.tail(this._path), fn, Object.keys(resolvables), common_1.extend({ when: "Later" }, options));
	        var getPromise = function (resolvable) { return resolvable.get(_this, options); };
	        var promises = common_1.map(resolvables, getPromise);
	        return coreservices_1.services.$q.all(promises).then(function () {
	            try {
	                return _this.invokeNow(fn, locals, options);
	            }
	            catch (error) {
	                return coreservices_1.services.$q.reject(error);
	            }
	        });
	    };
	    ResolveContext.prototype.invokeNow = function (fn, locals, options) {
	        if (options === void 0) { options = {}; }
	        var resolvables = this.getResolvablesForFn(fn);
	        trace_1.trace.tracePathElementInvoke(common_1.tail(this._path), fn, Object.keys(resolvables), common_1.extend({ when: "Now  " }, options));
	        var resolvedLocals = common_1.map(resolvables, hof_1.prop("data"));
	        return coreservices_1.services.$injector.invoke(fn, null, common_1.extend({}, locals, resolvedLocals));
	    };
	    return ResolveContext;
	})();
	exports.ResolveContext = ResolveContext;
	function getPolicy(stateResolvePolicyConf, resolvable) {
	    var stateLevelPolicy = (predicates_1.isString(stateResolvePolicyConf) ? stateResolvePolicyConf : null);
	    var resolveLevelPolicies = (predicates_1.isObject(stateResolvePolicyConf) ? stateResolvePolicyConf : {});
	    var policyName = resolveLevelPolicies[resolvable.name] || stateLevelPolicy || defaultResolvePolicy;
	    return interface_1.ResolvePolicy[policyName];
	}
	//# sourceMappingURL=resolveContext.js.map

/***/ },
/* 41 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var ResolveInjector = (function () {
	    function ResolveInjector(_resolveContext, _state) {
	        this._resolveContext = _resolveContext;
	        this._state = _state;
	    }
	    ResolveInjector.prototype.invokeLater = function (injectedFn, locals) {
	        return this._resolveContext.invokeLater(injectedFn, locals);
	    };
	    ResolveInjector.prototype.invokeNow = function (injectedFn, locals) {
	        return this._resolveContext.invokeNow(null, injectedFn, locals);
	    };
	    ResolveInjector.prototype.getLocals = function (injectedFn) {
	        var _this = this;
	        var resolve = function (r) { return r.get(_this._resolveContext); };
	        return common_1.map(this._resolveContext.getResolvablesForFn(injectedFn), resolve);
	    };
	    return ResolveInjector;
	})();
	exports.ResolveInjector = ResolveInjector;
	//# sourceMappingURL=resolveInjector.js.map

/***/ },
/* 42 */
/***/ function(module, exports, __webpack_require__) {

	"use strict";
	var common_1 = __webpack_require__(4);
	var hof_1 = __webpack_require__(6);
	var predicates_1 = __webpack_require__(5);
	var module_1 = __webpack_require__(3);
	var coreservices_1 = __webpack_require__(7);
	function normalizeUiViewTarget(rawViewName) {
	    if (rawViewName === void 0) { rawViewName = ""; }
	    var viewAtContext = rawViewName.split("@");
	    var uiViewName = viewAtContext[0] || "$default";
	    var uiViewContextAnchor = predicates_1.isString(viewAtContext[1]) ? viewAtContext[1] : "^";
	    var relativeViewNameSugar = /^(\^(?:\.\^)*)\.(.*$)/.exec(uiViewName);
	    if (relativeViewNameSugar) {
	        uiViewContextAnchor = relativeViewNameSugar[1];
	        uiViewName = relativeViewNameSugar[2];
	    }
	    if (uiViewName.charAt(0) === '!') {
	        uiViewName = uiViewName.substr(1);
	        uiViewContextAnchor = "";
	    }
	    return { uiViewName: uiViewName, uiViewContextAnchor: uiViewContextAnchor };
	}
	var ViewConfig = (function () {
	    function ViewConfig(stateViewConfig) {
	        var _a = normalizeUiViewTarget(stateViewConfig.rawViewName), uiViewName = _a.uiViewName, uiViewContextAnchor = _a.uiViewContextAnchor;
	        var relativeMatch = /^(\^(?:\.\^)*)$/;
	        if (relativeMatch.exec(uiViewContextAnchor)) {
	            var anchor = uiViewContextAnchor.split(".").reduce((function (anchor, x) { return anchor.parent; }), stateViewConfig.context);
	            uiViewContextAnchor = anchor.name;
	        }
	        common_1.extend(this, common_1.pick(stateViewConfig, "viewDeclarationObj", "params", "context", "locals"), { uiViewName: uiViewName, uiViewContextAnchor: uiViewContextAnchor });
	        this.controllerAs = stateViewConfig.viewDeclarationObj.controllerAs;
	    }
	    ViewConfig.prototype.hasTemplate = function () {
	        var viewDef = this.viewDeclarationObj;
	        return !!(viewDef.template || viewDef.templateUrl || viewDef.templateProvider);
	    };
	    ViewConfig.prototype.getTemplate = function ($factory, injector) {
	        return $factory.fromConfig(this.viewDeclarationObj, this.params, injector.invokeLater.bind(injector));
	    };
	    ViewConfig.prototype.getController = function (injector) {
	        var provider = this.viewDeclarationObj.controllerProvider;
	        return predicates_1.isInjectable(provider) ? injector.invokeLater(provider, {}) : this.viewDeclarationObj.controller;
	    };
	    return ViewConfig;
	})();
	exports.ViewConfig = ViewConfig;
	var match = function (obj1) {
	    var keys = [];
	    for (var _i = 1; _i < arguments.length; _i++) {
	        keys[_i - 1] = arguments[_i];
	    }
	    return function (obj2) { return keys.reduce((function (memo, key) { return memo && obj1[key] === obj2[key]; }), true); };
	};
	var ViewService = (function () {
	    function ViewService($templateFactory) {
	        var _this = this;
	        this.$templateFactory = $templateFactory;
	        this.uiViews = [];
	        this.viewConfigs = [];
	        this.sync = function () {
	            var uiViewsByFqn = _this.uiViews.map(function (uiv) { return [uiv.fqn, uiv]; }).reduce(common_1.applyPairs, {});
	            var matches = hof_1.curry(function (uiView, viewConfig) {
	                var vcSegments = viewConfig.uiViewName.split(".");
	                var uivSegments = uiView.fqn.split(".");
	                if (!common_1.equals(vcSegments, uivSegments.slice(0 - vcSegments.length)))
	                    return false;
	                var negOffset = (1 - vcSegments.length) || undefined;
	                var fqnToFirstSegment = uivSegments.slice(0, negOffset).join(".");
	                var uiViewContext = uiViewsByFqn[fqnToFirstSegment].creationContext;
	                return viewConfig.uiViewContextAnchor === (uiViewContext && uiViewContext.name);
	            });
	            function uiViewDepth(uiView) {
	                return uiView.fqn.split(".").length;
	            }
	            function viewConfigDepth(config) {
	                var context = config.context, count = 0;
	                while (++count && context.parent)
	                    context = context.parent;
	                return count;
	            }
	            var depthCompare = hof_1.curry(function (depthFn, posNeg, left, right) { return posNeg * (depthFn(left) - depthFn(right)); });
	            var matchingConfigPair = function (uiView) {
	                var matchingConfigs = _this.viewConfigs.filter(matches(uiView));
	                if (matchingConfigs.length > 1)
	                    matchingConfigs.sort(depthCompare(viewConfigDepth, -1));
	                return [uiView, matchingConfigs[0]];
	            };
	            var configureUiView = function (_a) {
	                var uiView = _a[0], viewConfig = _a[1];
	                if (_this.uiViews.indexOf(uiView) !== -1)
	                    uiView.configUpdated(viewConfig);
	            };
	            _this.uiViews.sort(depthCompare(uiViewDepth, 1)).map(matchingConfigPair).forEach(configureUiView);
	        };
	    }
	    ViewService.prototype.rootContext = function (context) {
	        return this._rootContext = context || this._rootContext;
	    };
	    ;
	    ViewService.prototype.load = function (viewConfig, injector) {
	        if (!viewConfig.hasTemplate())
	            throw new Error("No template configuration specified for '" + viewConfig.uiViewName + "@" + viewConfig.uiViewContextAnchor + "'");
	        var $q = coreservices_1.services.$q;
	        var promises = {
	            template: $q.when(viewConfig.getTemplate(this.$templateFactory, injector)),
	            controller: $q.when(viewConfig.getController(injector))
	        };
	        return $q.all(promises).then(function (results) {
	            module_1.trace.traceViewServiceEvent("Loaded", viewConfig);
	            return common_1.extend(viewConfig, results);
	        });
	    };
	    ;
	    ViewService.prototype.reset = function (viewConfig) {
	        module_1.trace.traceViewServiceEvent("<- Removing", viewConfig);
	        this.viewConfigs.filter(match(viewConfig, "uiViewName", "context")).forEach(common_1.removeFrom(this.viewConfigs));
	    };
	    ;
	    ViewService.prototype.registerStateViewConfig = function (viewConfig) {
	        module_1.trace.traceViewServiceEvent("-> Registering", viewConfig);
	        this.viewConfigs.push(viewConfig);
	    };
	    ;
	    ViewService.prototype.registerUiView = function (uiView) {
	        module_1.trace.traceViewServiceUiViewEvent("-> Registering", uiView);
	        var uiViews = this.uiViews;
	        var fqnMatches = function (uiv) { return uiv.fqn === uiView.fqn; };
	        if (uiViews.filter(fqnMatches).length)
	            module_1.trace.traceViewServiceUiViewEvent("!!!! duplicate uiView named:", uiView);
	        uiViews.push(uiView);
	        this.sync();
	        return function () {
	            var idx = uiViews.indexOf(uiView);
	            if (idx <= 0) {
	                module_1.trace.traceViewServiceUiViewEvent("Tried removing non-registered uiView", uiView);
	                return;
	            }
	            module_1.trace.traceViewServiceUiViewEvent("<- Deregistering", uiView);
	            common_1.removeFrom(uiViews)(uiView);
	        };
	    };
	    ;
	    ViewService.prototype.available = function () {
	        return this.uiViews.map(hof_1.prop("fqn"));
	    };
	    ViewService.prototype.active = function () {
	        return this.uiViews.filter(hof_1.prop("$config")).map(hof_1.prop("name"));
	    };
	    return ViewService;
	})();
	exports.ViewService = ViewService;
	//# sourceMappingURL=view.js.map

/***/ },
/* 43 */
/***/ function(module, exports, __webpack_require__) {

	var transition_1 = __webpack_require__(11);
	var hookRegistry_1 = __webpack_require__(14);
	exports.defaultTransOpts = {
	    location: true,
	    relative: null,
	    inherit: false,
	    notify: true,
	    reload: false,
	    custom: {},
	    current: function () { return null; }
	};
	var TransitionService = (function () {
	    function TransitionService() {
	        this._defaultErrorHandler = function $defaultErrorHandler($error$) {
	            if ($error$ instanceof Error)
	                console.log($error$);
	        };
	        hookRegistry_1.HookRegistry.mixin(new hookRegistry_1.HookRegistry(), this);
	    }
	    TransitionService.prototype.defaultErrorHandler = function (handler) {
	        return this._defaultErrorHandler = handler || this._defaultErrorHandler;
	    };
	    TransitionService.prototype.create = function (fromPath, targetState) {
	        return new transition_1.Transition(fromPath, targetState, this);
	    };
	    return TransitionService;
	})();
	exports.TransitionService = TransitionService;
	//# sourceMappingURL=transitionService.js.map

/***/ },
/* 44 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var predicates_1 = __webpack_require__(5);
	var hof_1 = __webpack_require__(6);
	var trace_1 = __webpack_require__(9);
	var coreservices_1 = __webpack_require__(7);
	var rejectFactory_1 = __webpack_require__(26);
	var module_1 = __webpack_require__(15);
	var REJECT = new rejectFactory_1.RejectFactory();
	var defaultOptions = {
	    async: true,
	    rejectIfSuperseded: true,
	    current: common_1.noop,
	    transition: null,
	    traceData: {}
	};
	var TransitionHook = (function () {
	    function TransitionHook(fn, locals, resolveContext, options) {
	        var _this = this;
	        this.fn = fn;
	        this.locals = locals;
	        this.resolveContext = resolveContext;
	        this.options = options;
	        this.isSuperseded = function () { return _this.options.current() !== _this.options.transition; };
	        this.mapHookResult = hof_1.pattern([
	            [this.isSuperseded, function () { return REJECT.superseded(_this.options.current()); }],
	            [hof_1.eq(false), function () { return REJECT.aborted("Hook aborted transition"); }],
	            [hof_1.is(module_1.TargetState), function (target) { return REJECT.redirected(target); }],
	            [predicates_1.isPromise, function (promise) { return promise.then(_this.handleHookResult.bind(_this)); }]
	        ]);
	        this.invokeStep = function (moreLocals) {
	            var _a = _this, options = _a.options, fn = _a.fn, resolveContext = _a.resolveContext;
	            var locals = common_1.extend({}, _this.locals, moreLocals);
	            trace_1.trace.traceHookInvocation(_this, options);
	            if (options.rejectIfSuperseded && _this.isSuperseded()) {
	                return REJECT.superseded(options.current());
	            }
	            if (!options.async) {
	                var hookResult = resolveContext.invokeNow(fn, locals, options);
	                return _this.handleHookResult(hookResult);
	            }
	            return resolveContext.invokeLater(fn, locals, options).then(_this.handleHookResult.bind(_this));
	        };
	        this.options = common_1.defaults(options, defaultOptions);
	    }
	    TransitionHook.prototype.handleHookResult = function (hookResult) {
	        if (!predicates_1.isDefined(hookResult))
	            return undefined;
	        trace_1.trace.traceHookResult(hookResult, undefined, this.options);
	        var transitionResult = this.mapHookResult(hookResult);
	        if (transitionResult)
	            trace_1.trace.traceHookResult(hookResult, transitionResult, this.options);
	        return transitionResult;
	    };
	    TransitionHook.prototype.toString = function () {
	        var _a = this, options = _a.options, fn = _a.fn;
	        var event = hof_1.parse("traceData.hookType")(options) || "internal", context = hof_1.parse("traceData.context.state.name")(options) || hof_1.parse("traceData.context")(options) || "unknown", name = common_1.fnToString(fn);
	        return event + " context: " + context + ", " + common_1.maxLength(200, name);
	    };
	    TransitionHook.runSynchronousHooks = function (hooks, locals, swallowExceptions) {
	        if (locals === void 0) { locals = {}; }
	        if (swallowExceptions === void 0) { swallowExceptions = false; }
	        var results = [];
	        for (var i = 0; i < hooks.length; i++) {
	            try {
	                results.push(hooks[i].invokeStep(locals));
	            }
	            catch (exception) {
	                if (!swallowExceptions)
	                    throw exception;
	                console.log("Swallowed exception during synchronous hook handler: " + exception);
	            }
	        }
	        var rejections = results.filter(TransitionHook.isRejection);
	        if (rejections.length)
	            return rejections[0];
	        return results
	            .filter(hof_1.not(TransitionHook.isRejection))
	            .filter(predicates_1.isPromise)
	            .reduce(function (chain, promise) { return chain.then(hof_1.val(promise)); }, coreservices_1.services.$q.when());
	    };
	    TransitionHook.isRejection = function (hookResult) {
	        return hookResult && hookResult.reason instanceof rejectFactory_1.TransitionRejection && hookResult;
	    };
	    return TransitionHook;
	})();
	exports.TransitionHook = TransitionHook;
	//# sourceMappingURL=transitionHook.js.map

/***/ },
/* 45 */
/***/ function(module, exports, __webpack_require__) {

	function __export(m) {
	    for (var p in m) if (!exports.hasOwnProperty(p)) exports[p] = m[p];
	}
	__export(__webpack_require__(46));
	__export(__webpack_require__(21));
	__export(__webpack_require__(47));
	__export(__webpack_require__(48));
	//# sourceMappingURL=module.js.map

/***/ },
/* 46 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var hof_1 = __webpack_require__(6);
	var predicates_1 = __webpack_require__(5);
	var module_1 = __webpack_require__(19);
	var predicates_2 = __webpack_require__(5);
	var param_1 = __webpack_require__(20);
	var common_2 = __webpack_require__(4);
	var common_3 = __webpack_require__(4);
	function quoteRegExp(string, param) {
	    var surroundPattern = ['', ''], result = string.replace(/[\\\[\]\^$*+?.()|{}]/g, "\\$&");
	    if (!param)
	        return result;
	    switch (param.squash) {
	        case false:
	            surroundPattern = ['(', ')' + (param.isOptional ? '?' : '')];
	            break;
	        case true:
	            result = result.replace(/\/$/, '');
	            surroundPattern = ['(?:\/(', ')|\/)?'];
	            break;
	        default:
	            surroundPattern = [("(" + param.squash + "|"), ')?'];
	            break;
	    }
	    return result + surroundPattern[0] + param.type.pattern.source + surroundPattern[1];
	}
	var memoizeTo = function (obj, prop, fn) { return obj[prop] = obj[prop] || fn(); };
	var UrlMatcher = (function () {
	    function UrlMatcher(pattern, config) {
	        var _this = this;
	        this.pattern = pattern;
	        this.config = config;
	        this._cache = { path: [], pattern: null };
	        this._children = [];
	        this._params = [];
	        this._segments = [];
	        this._compiled = [];
	        this.config = common_1.defaults(this.config, {
	            params: {},
	            strict: true,
	            caseInsensitive: false,
	            paramMap: common_1.identity
	        });
	        var placeholder = /([:*])([\w\[\]]+)|\{([\w\[\]]+)(?:\:\s*((?:[^{}\\]+|\\.|\{(?:[^{}\\]+|\\.)*\})+))?\}/g, searchPlaceholder = /([:]?)([\w\[\].-]+)|\{([\w\[\].-]+)(?:\:\s*((?:[^{}\\]+|\\.|\{(?:[^{}\\]+|\\.)*\})+))?\}/g, last = 0, m, patterns = [];
	        var checkParamErrors = function (id) {
	            if (!UrlMatcher.nameValidator.test(id))
	                throw new Error("Invalid parameter name '" + id + "' in pattern '" + pattern + "'");
	            if (common_1.find(_this._params, hof_1.propEq('id', id)))
	                throw new Error("Duplicate parameter name '" + id + "' in pattern '" + pattern + "'");
	        };
	        var matchDetails = function (m, isSearch) {
	            var id = m[2] || m[3], regexp = isSearch ? m[4] : m[4] || (m[1] === '*' ? '.*' : null);
	            return {
	                id: id,
	                regexp: regexp,
	                cfg: _this.config.params[id],
	                segment: pattern.substring(last, m.index),
	                type: !regexp ? null : module_1.paramTypes.type(regexp || "string") || common_1.inherit(module_1.paramTypes.type("string"), {
	                    pattern: new RegExp(regexp, _this.config.caseInsensitive ? 'i' : undefined)
	                })
	            };
	        };
	        var p, segment;
	        while ((m = placeholder.exec(pattern))) {
	            p = matchDetails(m, false);
	            if (p.segment.indexOf('?') >= 0)
	                break;
	            checkParamErrors(p.id);
	            this._params.push(module_1.Param.fromPath(p.id, p.type, this.config.paramMap(p.cfg, false)));
	            this._segments.push(p.segment);
	            patterns.push([p.segment, common_1.tail(this._params)]);
	            last = placeholder.lastIndex;
	        }
	        segment = pattern.substring(last);
	        var i = segment.indexOf('?');
	        if (i >= 0) {
	            var search = segment.substring(i);
	            segment = segment.substring(0, i);
	            if (search.length > 0) {
	                last = 0;
	                while ((m = searchPlaceholder.exec(search))) {
	                    p = matchDetails(m, true);
	                    checkParamErrors(p.id);
	                    this._params.push(module_1.Param.fromSearch(p.id, p.type, this.config.paramMap(p.cfg, true)));
	                    last = placeholder.lastIndex;
	                }
	            }
	        }
	        this._segments.push(segment);
	        common_1.extend(this, {
	            _compiled: patterns.map(function (pattern) { return quoteRegExp.apply(null, pattern); }).concat(quoteRegExp(segment)),
	            prefix: this._segments[0]
	        });
	        Object.freeze(this);
	    }
	    UrlMatcher.prototype.append = function (url) {
	        this._children.push(url);
	        common_1.forEach(url._cache, function (val, key) { return url._cache[key] = predicates_1.isArray(val) ? [] : null; });
	        url._cache.path = this._cache.path.concat(this);
	        return url;
	    };
	    UrlMatcher.prototype.isRoot = function () {
	        return this._cache.path.length === 0;
	    };
	    UrlMatcher.prototype.toString = function () {
	        return this.pattern;
	    };
	    UrlMatcher.prototype.exec = function (path, search, hash, options) {
	        var _this = this;
	        if (search === void 0) { search = {}; }
	        if (options === void 0) { options = {}; }
	        var match = memoizeTo(this._cache, 'pattern', function () {
	            return new RegExp([
	                '^',
	                common_1.unnest(_this._cache.path.concat(_this).map(hof_1.prop('_compiled'))).join(''),
	                _this.config.strict === false ? '\/?' : '',
	                '$'
	            ].join(''), _this.config.caseInsensitive ? 'i' : undefined);
	        }).exec(path);
	        if (!match)
	            return null;
	        var allParams = this.parameters(), pathParams = allParams.filter(function (param) { return !param.isSearch(); }), searchParams = allParams.filter(function (param) { return param.isSearch(); }), nPathSegments = this._cache.path.concat(this).map(function (urlm) { return urlm._segments.length - 1; }).reduce(function (a, x) { return a + x; }), values = {};
	        if (nPathSegments !== match.length - 1)
	            throw new Error("Unbalanced capture group in route '" + this.pattern + "'");
	        function decodePathArray(string) {
	            var reverseString = function (str) { return str.split("").reverse().join(""); };
	            var unquoteDashes = function (str) { return str.replace(/\\-/g, "-"); };
	            var split = reverseString(string).split(/-(?!\\)/);
	            var allReversed = common_1.map(split, reverseString);
	            return common_1.map(allReversed, unquoteDashes).reverse();
	        }
	        for (var i = 0; i < nPathSegments; i++) {
	            var param = pathParams[i];
	            var value = match[i + 1];
	            for (var j = 0; j < param.replace.length; j++) {
	                if (param.replace[j].from === value)
	                    value = param.replace[j].to;
	            }
	            if (value && param.array === true)
	                value = decodePathArray(value);
	            if (predicates_2.isDefined(value))
	                value = param.type.decode(value);
	            values[param.id] = param.value(value);
	        }
	        common_1.forEach(searchParams, function (param) {
	            var value = search[param.id];
	            for (var j = 0; j < param.replace.length; j++) {
	                if (param.replace[j].from === value)
	                    value = param.replace[j].to;
	            }
	            if (predicates_2.isDefined(value))
	                value = param.type.decode(value);
	            values[param.id] = param.value(value);
	        });
	        if (hash)
	            values["#"] = hash;
	        return values;
	    };
	    UrlMatcher.prototype.parameters = function (opts) {
	        if (opts === void 0) { opts = {}; }
	        if (opts.inherit === false)
	            return this._params;
	        return common_1.unnest(this._cache.path.concat(this).map(hof_1.prop('_params')));
	    };
	    UrlMatcher.prototype.parameter = function (id, opts) {
	        if (opts === void 0) { opts = {}; }
	        var parent = common_1.tail(this._cache.path);
	        return (common_1.find(this._params, hof_1.propEq('id', id)) ||
	            (opts.inherit !== false && parent && parent.parameter(id)) ||
	            null);
	    };
	    UrlMatcher.prototype.validates = function (params) {
	        var _this = this;
	        var validParamVal = function (param, val) { return !param || param.validates(val); };
	        return common_1.pairs(params || {}).map(function (_a) {
	            var key = _a[0], val = _a[1];
	            return validParamVal(_this.parameter(key), val);
	        }).reduce(common_1.allTrueR, true);
	    };
	    UrlMatcher.prototype.format = function (values) {
	        if (values === void 0) { values = {}; }
	        if (!this.validates(values))
	            return null;
	        var urlMatchers = this._cache.path.slice().concat(this);
	        var pathSegmentsAndParams = urlMatchers.map(UrlMatcher.pathSegmentsAndParams).reduce(common_2.unnestR, []);
	        var queryParams = urlMatchers.map(UrlMatcher.queryParams).reduce(common_2.unnestR, []);
	        function getDetails(param) {
	            var value = param.value(values[param.id]);
	            var isDefaultValue = param.isDefaultValue(value);
	            var squash = isDefaultValue ? param.squash : false;
	            var encoded = param.type.encode(value);
	            return { param: param, value: value, isDefaultValue: isDefaultValue, squash: squash, encoded: encoded };
	        }
	        var pathString = pathSegmentsAndParams.reduce(function (acc, x) {
	            if (predicates_1.isString(x))
	                return acc + x;
	            var _a = getDetails(x), squash = _a.squash, encoded = _a.encoded, param = _a.param;
	            if (squash === true)
	                return (acc.match(/\/$/)) ? acc.slice(0, -1) : acc;
	            if (predicates_1.isString(squash))
	                return acc + squash;
	            if (squash !== false)
	                return acc;
	            if (encoded == null)
	                return acc;
	            if (predicates_1.isArray(encoded))
	                return acc + common_1.map(encoded, UrlMatcher.encodeDashes).join("-");
	            if (param.type.raw)
	                return acc + encoded;
	            return acc + encodeURIComponent(encoded);
	        }, "");
	        var queryString = queryParams.map(function (param) {
	            var _a = getDetails(param), squash = _a.squash, encoded = _a.encoded, isDefaultValue = _a.isDefaultValue;
	            if (encoded == null || (isDefaultValue && squash !== false))
	                return;
	            if (!predicates_1.isArray(encoded))
	                encoded = [encoded];
	            if (encoded.length === 0)
	                return;
	            if (!param.type.raw)
	                encoded = common_1.map(encoded, encodeURIComponent);
	            return encoded.map(function (val) { return (param.id + "=" + val); });
	        }).filter(common_1.identity).reduce(common_2.unnestR, []).join("&");
	        return pathString + (queryString ? "?" + queryString : "") + (values["#"] ? "#" + values["#"] : "");
	    };
	    UrlMatcher.encodeDashes = function (str) {
	        return encodeURIComponent(str).replace(/-/g, function (c) { return ("%5C%" + c.charCodeAt(0).toString(16).toUpperCase()); });
	    };
	    UrlMatcher.pathSegmentsAndParams = function (matcher) {
	        var staticSegments = matcher._segments;
	        var pathParams = matcher._params.filter(function (p) { return p.location === param_1.DefType.PATH; });
	        return common_3.arrayTuples(staticSegments, pathParams.concat(undefined)).reduce(common_2.unnestR, []).filter(function (x) { return x !== "" && predicates_2.isDefined(x); });
	    };
	    UrlMatcher.queryParams = function (matcher) {
	        return matcher._params.filter(function (p) { return p.location === param_1.DefType.SEARCH; });
	    };
	    UrlMatcher.nameValidator = /^\w+([-.]+\w+)*(?:\[\])?$/;
	    return UrlMatcher;
	})();
	exports.UrlMatcher = UrlMatcher;
	//# sourceMappingURL=urlMatcher.js.map

/***/ },
/* 47 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var predicates_1 = __webpack_require__(5);
	var module_1 = __webpack_require__(45);
	var module_2 = __webpack_require__(19);
	function getDefaultConfig() {
	    return {
	        strict: module_1.matcherConfig.strictMode(),
	        caseInsensitive: module_1.matcherConfig.caseInsensitive()
	    };
	}
	var UrlMatcherFactory = (function () {
	    function UrlMatcherFactory() {
	        common_1.extend(this, { UrlMatcher: module_1.UrlMatcher, Param: module_2.Param });
	    }
	    UrlMatcherFactory.prototype.caseInsensitive = function (value) {
	        return module_1.matcherConfig.caseInsensitive(value);
	    };
	    UrlMatcherFactory.prototype.strictMode = function (value) {
	        return module_1.matcherConfig.strictMode(value);
	    };
	    UrlMatcherFactory.prototype.defaultSquashPolicy = function (value) {
	        return module_1.matcherConfig.defaultSquashPolicy(value);
	    };
	    UrlMatcherFactory.prototype.compile = function (pattern, config) {
	        return new module_1.UrlMatcher(pattern, common_1.extend(getDefaultConfig(), config));
	    };
	    UrlMatcherFactory.prototype.isMatcher = function (object) {
	        if (!predicates_1.isObject(object))
	            return false;
	        var result = true;
	        common_1.forEach(module_1.UrlMatcher.prototype, function (val, name) {
	            if (predicates_1.isFunction(val))
	                result = result && (predicates_1.isDefined(object[name]) && predicates_1.isFunction(object[name]));
	        });
	        return result;
	    };
	    ;
	    UrlMatcherFactory.prototype.type = function (name, definition, definitionFn) {
	        var type = module_2.paramTypes.type(name, definition, definitionFn);
	        return !predicates_1.isDefined(definition) ? type : this;
	    };
	    ;
	    UrlMatcherFactory.prototype.$get = function () {
	        module_2.paramTypes.enqueue = false;
	        module_2.paramTypes._flushTypeQueue();
	        return this;
	    };
	    ;
	    return UrlMatcherFactory;
	})();
	exports.UrlMatcherFactory = UrlMatcherFactory;
	//# sourceMappingURL=urlMatcherFactory.js.map

/***/ },
/* 48 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var predicates_1 = __webpack_require__(5);
	var coreservices_1 = __webpack_require__(7);
	var $location = coreservices_1.services.location;
	function regExpPrefix(re) {
	    var prefix = /^\^((?:\\[^a-zA-Z0-9]|[^\\\[\]\^$*+?.()|{}]+)*)/.exec(re.source);
	    return (prefix != null) ? prefix[1].replace(/\\(.)/g, "$1") : '';
	}
	function interpolate(pattern, match) {
	    return pattern.replace(/\$(\$|\d{1,2})/, function (m, what) {
	        return match[what === '$' ? 0 : Number(what)];
	    });
	}
	function handleIfMatch($injector, $stateParams, handler, match) {
	    if (!match)
	        return false;
	    var result = $injector.invoke(handler, handler, { $match: match, $stateParams: $stateParams });
	    return predicates_1.isDefined(result) ? result : true;
	}
	function appendBasePath(url, isHtml5, absolute) {
	    var baseHref = coreservices_1.services.locationConfig.baseHref();
	    if (baseHref === '/')
	        return url;
	    if (isHtml5)
	        return baseHref.slice(0, -1) + url;
	    if (absolute)
	        return baseHref.slice(1) + url;
	    return url;
	}
	function update(rules, otherwiseFn, evt) {
	    if (evt && evt.defaultPrevented)
	        return;
	    function check(rule) {
	        var handled = rule(coreservices_1.services.$injector, $location);
	        if (!handled)
	            return false;
	        if (predicates_1.isString(handled)) {
	            $location.replace();
	            $location.url(handled);
	        }
	        return true;
	    }
	    var n = rules.length, i;
	    for (i = 0; i < n; i++) {
	        if (check(rules[i]))
	            return;
	    }
	    if (otherwiseFn)
	        check(otherwiseFn);
	}
	var UrlRouterProvider = (function () {
	    function UrlRouterProvider($urlMatcherFactory, $stateParams) {
	        this.$urlMatcherFactory = $urlMatcherFactory;
	        this.$stateParams = $stateParams;
	        this.rules = [];
	        this.otherwiseFn = null;
	        this.interceptDeferred = false;
	    }
	    UrlRouterProvider.prototype.rule = function (rule) {
	        if (!predicates_1.isFunction(rule))
	            throw new Error("'rule' must be a function");
	        this.rules.push(rule);
	        return this;
	    };
	    ;
	    UrlRouterProvider.prototype.otherwise = function (rule) {
	        if (!predicates_1.isFunction(rule) && !predicates_1.isString(rule))
	            throw new Error("'rule' must be a string or function");
	        this.otherwiseFn = predicates_1.isString(rule) ? function () { return rule; } : rule;
	        return this;
	    };
	    ;
	    UrlRouterProvider.prototype.when = function (what, handler) {
	        var _a = this, $urlMatcherFactory = _a.$urlMatcherFactory, $stateParams = _a.$stateParams;
	        var redirect, handlerIsString = predicates_1.isString(handler);
	        if (predicates_1.isString(what))
	            what = $urlMatcherFactory.compile(what);
	        if (!handlerIsString && !predicates_1.isFunction(handler) && !predicates_1.isArray(handler))
	            throw new Error("invalid 'handler' in when()");
	        var strategies = {
	            matcher: function (_what, _handler) {
	                if (handlerIsString) {
	                    redirect = $urlMatcherFactory.compile(_handler);
	                    _handler = ['$match', redirect.format.bind(redirect)];
	                }
	                return common_1.extend(function () {
	                    return handleIfMatch(coreservices_1.services.$injector, $stateParams, _handler, _what.exec($location.path(), $location.search(), $location.hash()));
	                }, {
	                    prefix: predicates_1.isString(_what.prefix) ? _what.prefix : ''
	                });
	            },
	            regex: function (_what, _handler) {
	                if (_what.global || _what.sticky)
	                    throw new Error("when() RegExp must not be global or sticky");
	                if (handlerIsString) {
	                    redirect = _handler;
	                    _handler = ['$match', function ($match) { return interpolate(redirect, $match); }];
	                }
	                return common_1.extend(function () {
	                    return handleIfMatch(coreservices_1.services.$injector, $stateParams, _handler, _what.exec($location.path()));
	                }, {
	                    prefix: regExpPrefix(_what)
	                });
	            }
	        };
	        var check = {
	            matcher: $urlMatcherFactory.isMatcher(what),
	            regex: what instanceof RegExp
	        };
	        for (var n in check) {
	            if (check[n])
	                return this.rule(strategies[n](what, handler));
	        }
	        throw new Error("invalid 'what' in when()");
	    };
	    ;
	    UrlRouterProvider.prototype.deferIntercept = function (defer) {
	        if (defer === undefined)
	            defer = true;
	        this.interceptDeferred = defer;
	    };
	    ;
	    return UrlRouterProvider;
	})();
	exports.UrlRouterProvider = UrlRouterProvider;
	var UrlRouter = (function () {
	    function UrlRouter(urlRouterProvider) {
	        this.urlRouterProvider = urlRouterProvider;
	        common_1.bindFunctions(UrlRouter.prototype, this, this);
	    }
	    UrlRouter.prototype.sync = function () {
	        update(this.urlRouterProvider.rules, this.urlRouterProvider.otherwiseFn);
	    };
	    UrlRouter.prototype.listen = function () {
	        var _this = this;
	        return this.listener = this.listener || $location.onChange(function (evt) { return update(_this.urlRouterProvider.rules, _this.urlRouterProvider.otherwiseFn, evt); });
	    };
	    UrlRouter.prototype.update = function (read) {
	        if (read) {
	            this.location = $location.url();
	            return;
	        }
	        if ($location.url() === this.location)
	            return;
	        $location.url(this.location);
	        $location.replace();
	    };
	    UrlRouter.prototype.push = function (urlMatcher, params, options) {
	        $location.url(urlMatcher.format(params || {}));
	        if (options && options.replace)
	            $location.replace();
	    };
	    UrlRouter.prototype.href = function (urlMatcher, params, options) {
	        if (!urlMatcher.validates(params))
	            return null;
	        var url = urlMatcher.format(params);
	        options = options || {};
	        var cfg = coreservices_1.services.locationConfig;
	        var isHtml5 = cfg.html5Mode();
	        if (!isHtml5 && url !== null) {
	            url = "#" + cfg.hashPrefix() + url;
	        }
	        url = appendBasePath(url, isHtml5, options.absolute);
	        if (!options.absolute || !url) {
	            return url;
	        }
	        var slash = (!isHtml5 && url ? '/' : ''), port = cfg.port();
	        port = (port === 80 || port === 443 ? '' : ':' + port);
	        return [cfg.protocol(), '://', cfg.host(), port, slash, url].join('');
	    };
	    return UrlRouter;
	})();
	exports.UrlRouter = UrlRouter;
	//# sourceMappingURL=urlRouter.js.map

/***/ },
/* 49 */
/***/ function(module, exports, __webpack_require__) {

	function __export(m) {
	    for (var p in m) if (!exports.hasOwnProperty(p)) exports[p] = m[p];
	}
	__export(__webpack_require__(50));
	__export(__webpack_require__(42));
	//# sourceMappingURL=module.js.map

/***/ },
/* 50 */
/***/ function(module, exports, __webpack_require__) {

	var predicates_1 = __webpack_require__(5);
	var coreservices_1 = __webpack_require__(7);
	var TemplateFactory = (function () {
	    function TemplateFactory() {
	    }
	    TemplateFactory.prototype.fromConfig = function (config, params, injectFn) {
	        return (predicates_1.isDefined(config.template) ? this.fromString(config.template, params) :
	            predicates_1.isDefined(config.templateUrl) ? this.fromUrl(config.templateUrl, params) :
	                predicates_1.isDefined(config.templateProvider) ? this.fromProvider(config.templateProvider, params, injectFn) :
	                    null);
	    };
	    ;
	    TemplateFactory.prototype.fromString = function (template, params) {
	        return predicates_1.isFunction(template) ? template(params) : template;
	    };
	    ;
	    TemplateFactory.prototype.fromUrl = function (url, params) {
	        if (predicates_1.isFunction(url))
	            url = url(params);
	        if (url == null)
	            return null;
	        return coreservices_1.services.template.get(url);
	    };
	    ;
	    TemplateFactory.prototype.fromProvider = function (provider, params, injectFn) {
	        return injectFn(provider);
	    };
	    ;
	    return TemplateFactory;
	})();
	exports.TemplateFactory = TemplateFactory;
	//# sourceMappingURL=templateFactory.js.map

/***/ },
/* 51 */
/***/ function(module, exports, __webpack_require__) {

	var urlMatcherFactory_1 = __webpack_require__(47);
	var urlRouter_1 = __webpack_require__(48);
	var state_1 = __webpack_require__(17);
	var stateParams_1 = __webpack_require__(24);
	var urlRouter_2 = __webpack_require__(48);
	var transitionService_1 = __webpack_require__(43);
	var templateFactory_1 = __webpack_require__(50);
	var view_1 = __webpack_require__(42);
	var stateRegistry_1 = __webpack_require__(52);
	var stateService_1 = __webpack_require__(35);
	var Router = (function () {
	    function Router() {
	        var _this = this;
	        this.stateParams = stateParams_1.stateParamsFactory();
	        this.urlMatcherFactory = new urlMatcherFactory_1.UrlMatcherFactory();
	        this.urlRouterProvider = new urlRouter_1.UrlRouterProvider(this.urlMatcherFactory, this.stateParams);
	        this.urlRouter = new urlRouter_2.UrlRouter(this.urlRouterProvider);
	        this.transitionService = new transitionService_1.TransitionService();
	        this.templateFactory = new templateFactory_1.TemplateFactory();
	        this.viewService = new view_1.ViewService(this.templateFactory);
	        this.stateRegistry = new stateRegistry_1.StateRegistry(this.urlMatcherFactory, this.urlRouterProvider, function () { return _this.stateService.$current; });
	        this.stateProvider = new state_1.StateProvider(this.stateRegistry);
	        this.stateService = new stateService_1.StateService(this.viewService, this.stateParams, this.urlRouter, this.transitionService, this.stateRegistry, this.stateProvider);
	        this.viewService.rootContext(this.stateRegistry.root());
	    }
	    return Router;
	})();
	exports.Router = Router;
	//# sourceMappingURL=router.js.map

/***/ },
/* 52 */
/***/ function(module, exports, __webpack_require__) {

	var stateMatcher_1 = __webpack_require__(33);
	var stateBuilder_1 = __webpack_require__(18);
	var stateQueueManager_1 = __webpack_require__(34);
	var StateRegistry = (function () {
	    function StateRegistry(urlMatcherFactory, urlRouterProvider, currentState) {
	        this.currentState = currentState;
	        this.states = {};
	        this.matcher = new stateMatcher_1.StateMatcher(this.states);
	        this.builder = new stateBuilder_1.StateBuilder(this.matcher, urlMatcherFactory);
	        this.stateQueue = new stateQueueManager_1.StateQueueManager(this.states, this.builder, urlRouterProvider);
	        var rootStateDef = {
	            name: '',
	            url: '^',
	            views: null,
	            params: {
	                '#': { value: null, type: 'hash' }
	            },
	            abstract: true
	        };
	        var _root = this._root = this.stateQueue.register(rootStateDef);
	        _root.navigable = null;
	    }
	    StateRegistry.prototype.root = function () {
	        return this._root;
	    };
	    StateRegistry.prototype.register = function (stateDefinition) {
	        return this.stateQueue.register(stateDefinition);
	    };
	    StateRegistry.prototype.get = function (stateOrName, base) {
	        var _this = this;
	        if (arguments.length === 0)
	            return Object.keys(this.states).map(function (name) { return _this.states[name].self; });
	        var found = this.matcher.find(stateOrName, base || this.currentState());
	        return found && found.self || null;
	    };
	    StateRegistry.prototype.decorator = function (name, func) {
	        return this.builder.builder(name, func);
	    };
	    return StateRegistry;
	})();
	exports.StateRegistry = StateRegistry;
	//# sourceMappingURL=stateRegistry.js.map

/***/ },
/* 53 */
/***/ function(module, exports, __webpack_require__) {

	var router_1 = __webpack_require__(51);
	var coreservices_1 = __webpack_require__(7);
	var common_1 = __webpack_require__(4);
	var hof_1 = __webpack_require__(6);
	var predicates_1 = __webpack_require__(5);
	var module_1 = __webpack_require__(37);
	var module_2 = __webpack_require__(39);
	var module_3 = __webpack_require__(15);
	var trace_1 = __webpack_require__(9);
	var app = angular.module("ui.router.angular1", []);
	angular.module('ui.router.util', ['ng', 'ui.router.init']);
	angular.module('ui.router.router', ['ui.router.util']);
	angular.module('ui.router.state', ['ui.router.router', 'ui.router.util', 'ui.router.angular1']);
	angular.module('ui.router', ['ui.router.init', 'ui.router.state', 'ui.router.angular1']);
	angular.module('ui.router.compat', ['ui.router']);
	function annotateController(controllerExpression) {
	    var $injector = coreservices_1.services.$injector;
	    var $controller = $injector.get("$controller");
	    var oldInstantiate = $injector.instantiate;
	    try {
	        var deps;
	        $injector.instantiate = function fakeInstantiate(constructorFunction) {
	            $injector.instantiate = oldInstantiate;
	            deps = $injector.annotate(constructorFunction);
	        };
	        $controller(controllerExpression, { $scope: {} });
	        return deps;
	    }
	    finally {
	        $injector.instantiate = oldInstantiate;
	    }
	}
	exports.annotateController = annotateController;
	runBlock.$inject = ['$injector', '$q'];
	function runBlock($injector, $q) {
	    coreservices_1.services.$injector = $injector;
	    coreservices_1.services.$q = $q;
	}
	app.run(runBlock);
	var router = null;
	ng1UIRouter.$inject = ['$locationProvider'];
	function ng1UIRouter($locationProvider) {
	    router = new router_1.Router();
	    common_1.bindFunctions($locationProvider, coreservices_1.services.locationConfig, $locationProvider, ['hashPrefix']);
	    var urlListeners = [];
	    coreservices_1.services.location.onChange = function (callback) {
	        urlListeners.push(callback);
	        return function () { return common_1.removeFrom(urlListeners)(callback); };
	    };
	    this.$get = $get;
	    $get.$inject = ['$location', '$browser', '$sniffer', '$rootScope', '$http', '$templateCache'];
	    function $get($location, $browser, $sniffer, $rootScope, $http, $templateCache) {
	        $rootScope.$on("$locationChangeSuccess", function (evt) { return urlListeners.forEach(function (fn) { return fn(evt); }); });
	        coreservices_1.services.locationConfig.html5Mode = function () {
	            var html5Mode = $locationProvider.html5Mode();
	            html5Mode = predicates_1.isObject(html5Mode) ? html5Mode.enabled : html5Mode;
	            return html5Mode && $sniffer.history;
	        };
	        coreservices_1.services.template.get = function (url) {
	            return $http.get(url, { cache: $templateCache, headers: { Accept: 'text/html' } }).then(hof_1.prop("data"));
	        };
	        common_1.bindFunctions($location, coreservices_1.services.location, $location, ["replace", "url", "path", "search", "hash"]);
	        common_1.bindFunctions($location, coreservices_1.services.locationConfig, $location, ['port', 'protocol', 'host']);
	        common_1.bindFunctions($browser, coreservices_1.services.locationConfig, $browser, ['baseHref']);
	        return router;
	    }
	}
	var resolveFactory = function () { return ({
	    resolve: function (invocables, locals, parent) {
	        if (locals === void 0) { locals = {}; }
	        var parentNode = new module_1.Node(new module_3.State({ params: {} }));
	        var node = new module_1.Node(new module_3.State({ params: {} }));
	        var context = new module_2.ResolveContext([parentNode, node]);
	        context.addResolvables(module_2.Resolvable.makeResolvables(invocables), node.state);
	        var resolveData = function (parentLocals) {
	            var rewrap = function (_locals) { return module_2.Resolvable.makeResolvables(common_1.map(_locals, function (local) { return function () { return local; }; })); };
	            context.addResolvables(rewrap(parentLocals), parentNode.state);
	            context.addResolvables(rewrap(locals), node.state);
	            return context.resolvePath();
	        };
	        return parent ? parent.then(resolveData) : resolveData({});
	    }
	}); };
	function $stateParamsFactory(ng1UIRouter, $rootScope) {
	    $rootScope.$watch(function () {
	        router.stateParams.$digest();
	    });
	    return router.stateParams;
	}
	angular.module('ui.router.init', []).provider("ng1UIRouter", ng1UIRouter);
	angular.module('ui.router.init').run(['ng1UIRouter', function (ng1UIRouter) { }]);
	angular.module('ui.router.util').provider('$urlMatcherFactory', ['ng1UIRouterProvider', function () { return router.urlMatcherFactory; }]);
	angular.module('ui.router.util').run(['$urlMatcherFactory', function ($urlMatcherFactory) { }]);
	function getUrlRouterProvider() {
	    router.urlRouterProvider["$get"] = function () {
	        router.urlRouter.update(true);
	        if (!this.interceptDeferred)
	            router.urlRouter.listen();
	        return router.urlRouter;
	    };
	    return router.urlRouterProvider;
	}
	angular.module('ui.router.router').provider('$urlRouter', ['ng1UIRouterProvider', getUrlRouterProvider]);
	angular.module('ui.router.router').run(['$urlRouter', function ($urlRouter) { }]);
	function getStateProvider() {
	    router.stateProvider["$get"] = function () {
	        router.stateRegistry.stateQueue.autoFlush(router.stateService);
	        return router.stateService;
	    };
	    return router.stateProvider;
	}
	angular.module('ui.router.state').provider('$state', ['ng1UIRouterProvider', getStateProvider]);
	angular.module('ui.router.state').run(['$state', function ($state) { }]);
	angular.module('ui.router.state').factory('$stateParams', ['ng1UIRouter', '$rootScope', $stateParamsFactory]);
	function getTransitionsProvider() {
	    loadAllControllerLocals.$inject = ['$transition$'];
	    function loadAllControllerLocals($transition$) {
	        var loadLocals = function (vc) {
	            var deps = annotateController(vc.controller);
	            var toPath = $transition$.treeChanges().to;
	            var resolveInjector = common_1.find(toPath, hof_1.propEq('state', vc.context)).resolveInjector;
	            function $loadControllerLocals() { }
	            $loadControllerLocals.$inject = deps;
	            return coreservices_1.services.$q.all(resolveInjector.getLocals($loadControllerLocals)).then(function (locals) { return vc.locals = locals; });
	        };
	        var loadAllLocals = $transition$.views("entering").filter(function (vc) { return !!vc.controller; }).map(loadLocals);
	        return coreservices_1.services.$q.all(loadAllLocals).then(common_1.noop);
	    }
	    router.transitionService.onFinish({}, loadAllControllerLocals);
	    router.transitionService["$get"] = function () { return router.transitionService; };
	    return router.transitionService;
	}
	angular.module('ui.router.state').provider('$transitions', ['ng1UIRouterProvider', getTransitionsProvider]);
	angular.module('ui.router.util').factory('$templateFactory', ['ng1UIRouter', function () { return router.templateFactory; }]);
	angular.module('ui.router').factory('$view', function () { return router.viewService; });
	angular.module('ui.router').factory('$resolve', resolveFactory);
	angular.module("ui.router").service("$trace", function () { return trace_1.trace; });
	watchDigests.$inject = ['$rootScope'];
	function watchDigests($rootScope) {
	    $rootScope.$watch(function () { trace_1.trace.approximateDigests++; });
	}
	exports.watchDigests = watchDigests;
	angular.module("ui.router").run(watchDigests);
	//# sourceMappingURL=services.js.map

/***/ },
/* 54 */
/***/ function(module, exports, __webpack_require__) {

	var common_1 = __webpack_require__(4);
	var predicates_1 = __webpack_require__(5);
	function parseStateRef(ref, current) {
	    var preparsed = ref.match(/^\s*({[^}]*})\s*$/), parsed;
	    if (preparsed)
	        ref = current + '(' + preparsed[1] + ')';
	    parsed = ref.replace(/\n/g, " ").match(/^([^(]+?)\s*(\((.*)\))?$/);
	    if (!parsed || parsed.length !== 4)
	        throw new Error("Invalid state ref '" + ref + "'");
	    return { state: parsed[1], paramExpr: parsed[3] || null };
	}
	function stateContext(el) {
	    var stateData = el.parent().inheritedData('$uiView');
	    if (stateData && stateData.context && stateData.context.name) {
	        return stateData.context;
	    }
	}
	function getTypeInfo(el) {
	    var isSvg = Object.prototype.toString.call(el.prop('href')) === '[object SVGAnimatedString]';
	    var isForm = el[0].nodeName === "FORM";
	    return {
	        attr: isForm ? "action" : (isSvg ? 'xlink:href' : 'href'),
	        isAnchor: el.prop("tagName").toUpperCase() === "A",
	        clickable: !isForm
	    };
	}
	function clickHook(el, $state, $timeout, type, current) {
	    return function (e) {
	        var button = e.which || e.button, target = current();
	        if (!(button > 1 || e.ctrlKey || e.metaKey || e.shiftKey || el.attr('target'))) {
	            var transition = $timeout(function () {
	                $state.go(target.state, target.params, target.options);
	            });
	            e.preventDefault();
	            var ignorePreventDefaultCount = type.isAnchor && !target.href ? 1 : 0;
	            e.preventDefault = function () {
	                if (ignorePreventDefaultCount-- <= 0)
	                    $timeout.cancel(transition);
	            };
	        }
	    };
	}
	function defaultOpts(el, $state) {
	    return { relative: stateContext(el) || $state.$current, inherit: true };
	}
	$StateRefDirective.$inject = ['$state', '$timeout'];
	function $StateRefDirective($state, $timeout) {
	    return {
	        restrict: 'A',
	        require: ['?^uiSrefActive', '?^uiSrefActiveEq'],
	        link: function (scope, element, attrs, uiSrefActive) {
	            var ref = parseStateRef(attrs.uiSref, $state.current.name);
	            var def = { state: ref.state, href: null, params: null, options: null };
	            var type = getTypeInfo(element);
	            var active = uiSrefActive[1] || uiSrefActive[0];
	            var unlinkInfoFn = null;
	            def.options = common_1.extend(defaultOpts(element, $state), attrs.uiSrefOpts ? scope.$eval(attrs.uiSrefOpts) : {});
	            var update = function (val) {
	                if (val)
	                    def.params = angular.copy(val);
	                def.href = $state.href(ref.state, def.params, def.options);
	                if (unlinkInfoFn)
	                    unlinkInfoFn();
	                if (active)
	                    unlinkInfoFn = active.$$addStateInfo(ref.state, def.params);
	                if (def.href !== null)
	                    attrs.$set(type.attr, def.href);
	            };
	            if (ref.paramExpr) {
	                scope.$watch(ref.paramExpr, function (val) { if (val !== def.params)
	                    update(val); }, true);
	                def.params = angular.copy(scope.$eval(ref.paramExpr));
	            }
	            update();
	            if (!type.clickable)
	                return;
	            element.bind("click", clickHook(element, $state, $timeout, type, function () { return def; }));
	        }
	    };
	}
	$StateRefDynamicDirective.$inject = ['$state', '$timeout'];
	function $StateRefDynamicDirective($state, $timeout) {
	    return {
	        restrict: 'A',
	        require: ['?^uiSrefActive', '?^uiSrefActiveEq'],
	        link: function (scope, element, attrs, uiSrefActive) {
	            var type = getTypeInfo(element);
	            var active = uiSrefActive[1] || uiSrefActive[0];
	            var group = [attrs.uiState, attrs.uiStateParams || null, attrs.uiStateOpts || null];
	            var watch = '[' + group.map(function (val) { return val || 'null'; }).join(', ') + ']';
	            var def = { state: null, params: null, options: null, href: null };
	            var unlinkInfoFn = null;
	            function runStateRefLink(group) {
	                def.state = group[0];
	                def.params = group[1];
	                def.options = group[2];
	                def.href = $state.href(def.state, def.params, def.options);
	                if (unlinkInfoFn)
	                    unlinkInfoFn();
	                if (active)
	                    unlinkInfoFn = active.$$addStateInfo(def.state, def.params);
	                if (def.href)
	                    attrs.$set(type.attr, def.href);
	            }
	            scope.$watch(watch, runStateRefLink, true);
	            runStateRefLink(scope.$eval(watch));
	            if (!type.clickable)
	                return;
	            element.bind("click", clickHook(element, $state, $timeout, type, function () { return def; }));
	        }
	    };
	}
	$StateRefActiveDirective.$inject = ['$state', '$stateParams', '$interpolate', '$transitions'];
	function $StateRefActiveDirective($state, $stateParams, $interpolate, $transitions) {
	    return {
	        restrict: "A",
	        controller: ['$scope', '$element', '$attrs', '$timeout', function ($scope, $element, $attrs, $timeout) {
	                var states = [], activeClasses = {}, activeEqClass, uiSrefActive;
	                activeEqClass = $interpolate($attrs.uiSrefActiveEq || '', false)($scope);
	                try {
	                    uiSrefActive = $scope.$eval($attrs.uiSrefActive);
	                }
	                catch (e) {
	                }
	                uiSrefActive = uiSrefActive || $interpolate($attrs.uiSrefActive || '', false)($scope);
	                if (predicates_1.isObject(uiSrefActive)) {
	                    common_1.forEach(uiSrefActive, function (stateOrName, activeClass) {
	                        if (predicates_1.isString(stateOrName)) {
	                            var ref = parseStateRef(stateOrName, $state.current.name);
	                            addState(ref.state, $scope.$eval(ref.paramExpr), activeClass);
	                        }
	                    });
	                }
	                this.$$addStateInfo = function (newState, newParams) {
	                    if (predicates_1.isObject(uiSrefActive) && states.length > 0) {
	                        return;
	                    }
	                    var deregister = addState(newState, newParams, uiSrefActive);
	                    update();
	                    return deregister;
	                };
	                $scope.$on('$stateChangeSuccess', update);
	                var updateAfterTransition = ['$transition$', function ($transition$) { $transition$.promise.then(update); }];
	                var deregisterFn = $transitions.onStart({}, updateAfterTransition);
	                $scope.$on('$destroy', deregisterFn);
	                function addState(stateName, stateParams, activeClass) {
	                    var state = $state.get(stateName, stateContext($element));
	                    var stateHash = createStateHash(stateName, stateParams);
	                    var stateInfo = {
	                        state: state || { name: stateName },
	                        params: stateParams,
	                        hash: stateHash
	                    };
	                    states.push(stateInfo);
	                    activeClasses[stateHash] = activeClass;
	                    return function removeState() {
	                        var idx = states.indexOf(stateInfo);
	                        if (idx !== -1)
	                            states.splice(idx, 1);
	                    };
	                }
	                function createStateHash(state, params) {
	                    if (!predicates_1.isString(state)) {
	                        throw new Error('state should be a string');
	                    }
	                    if (predicates_1.isObject(params)) {
	                        return state + common_1.toJson(params);
	                    }
	                    params = $scope.$eval(params);
	                    if (predicates_1.isObject(params)) {
	                        return state + common_1.toJson(params);
	                    }
	                    return state;
	                }
	                function update() {
	                    for (var i = 0; i < states.length; i++) {
	                        if (anyMatch(states[i].state, states[i].params)) {
	                            addClass($element, activeClasses[states[i].hash]);
	                        }
	                        else {
	                            removeClass($element, activeClasses[states[i].hash]);
	                        }
	                        if (exactMatch(states[i].state, states[i].params)) {
	                            addClass($element, activeEqClass);
	                        }
	                        else {
	                            removeClass($element, activeEqClass);
	                        }
	                    }
	                }
	                function addClass(el, className) { $timeout(function () { el.addClass(className); }); }
	                function removeClass(el, className) { el.removeClass(className); }
	                function anyMatch(state, params) { return $state.includes(state.name, params); }
	                function exactMatch(state, params) { return $state.is(state.name, params); }
	                update();
	            }]
	    };
	}
	angular.module('ui.router.state')
	    .directive('uiSref', $StateRefDirective)
	    .directive('uiSrefActive', $StateRefActiveDirective)
	    .directive('uiSrefActiveEq', $StateRefActiveDirective)
	    .directive('uiState', $StateRefDynamicDirective);
	//# sourceMappingURL=stateDirectives.js.map

/***/ },
/* 55 */
/***/ function(module, exports) {

	$IsStateFilter.$inject = ['$state'];
	function $IsStateFilter($state) {
	    var isFilter = function (state, params, options) {
	        return $state.is(state, params, options);
	    };
	    isFilter.$stateful = true;
	    return isFilter;
	}
	exports.$IsStateFilter = $IsStateFilter;
	$IncludedByStateFilter.$inject = ['$state'];
	function $IncludedByStateFilter($state) {
	    var includesFilter = function (state, params, options) {
	        return $state.includes(state, params, options);
	    };
	    includesFilter.$stateful = true;
	    return includesFilter;
	}
	exports.$IncludedByStateFilter = $IncludedByStateFilter;
	angular.module('ui.router.state')
	    .filter('isState', $IsStateFilter)
	    .filter('includedByState', $IncludedByStateFilter);
	//# sourceMappingURL=stateFilters.js.map

/***/ },
/* 56 */
/***/ function(module, exports, __webpack_require__) {

	var ngMajorVer = angular.version.major;
	var ngMinorVer = angular.version.minor;
	var common_1 = __webpack_require__(4);
	var predicates_1 = __webpack_require__(5);
	var trace_1 = __webpack_require__(9);
	$ViewDirective.$inject = ['$view', '$animate', '$uiViewScroll', '$interpolate', '$q'];
	function $ViewDirective($view, $animate, $uiViewScroll, $interpolate, $q) {
	    function getRenderer(attrs, scope) {
	        function animEnabled(element) {
	            if (!!attrs.noanimation)
	                return false;
	            return (ngMajorVer === 1 && ngMinorVer >= 4) ? !!$animate.enabled(element) : !!$animate.enabled();
	        }
	        return {
	            enter: function (element, target, cb) {
	                if (!animEnabled(element)) {
	                    target.after(element);
	                    cb();
	                }
	                else if (angular.version.minor > 2) {
	                    $animate.enter(element, null, target).then(cb);
	                }
	                else {
	                    $animate.enter(element, null, target, cb);
	                }
	            },
	            leave: function (element, cb) {
	                if (!animEnabled(element)) {
	                    element.remove();
	                    cb();
	                }
	                else if (angular.version.minor > 2) {
	                    $animate.leave(element).then(cb);
	                }
	                else {
	                    $animate.leave(element, cb);
	                }
	            }
	        };
	    }
	    function configsEqual(config1, config2) {
	        return config1 === config2;
	    }
	    var rootData = {
	        context: $view.rootContext()
	    };
	    var directive = {
	        count: 0,
	        restrict: 'ECA',
	        terminal: true,
	        priority: 400,
	        transclude: 'element',
	        compile: function (tElement, tAttrs, $transclude) {
	            return function (scope, $element, attrs) {
	                var previousEl, currentEl, currentScope, unregister, onloadExp = attrs.onload || '', autoScrollExp = attrs.autoscroll, renderer = getRenderer(attrs, scope), viewConfig = undefined, inherited = $element.inheritedData('$uiView') || rootData, name = $interpolate(attrs.uiView || attrs.name || '')(scope) || '$default';
	                var viewData = {
	                    id: directive.count++,
	                    name: name,
	                    fqn: inherited.name ? inherited.fqn + "." + name : name,
	                    config: null,
	                    configUpdated: configUpdatedCallback,
	                    get creationContext() { return inherited.context; }
	                };
	                trace_1.trace.traceUiViewEvent("Linking", viewData);
	                function configUpdatedCallback(config) {
	                    if (configsEqual(viewConfig, config) || scope._willBeDestroyed)
	                        return;
	                    trace_1.trace.traceUiViewConfigUpdated(viewData, config && config.context);
	                    viewConfig = config;
	                    updateView(config);
	                }
	                $element.data('$uiView', viewData);
	                updateView();
	                unregister = $view.registerUiView(viewData);
	                scope.$on("$destroy", function () {
	                    trace_1.trace.traceUiViewEvent("Destroying/Unregistering", viewData);
	                    unregister();
	                });
	                function cleanupLastView() {
	                    var _previousEl = previousEl;
	                    var _currentScope = currentScope;
	                    if (_currentScope) {
	                        _currentScope._willBeDestroyed = true;
	                    }
	                    function cleanOld() {
	                        if (_previousEl) {
	                            trace_1.trace.traceUiViewEvent("Removing    (previous) el", viewData);
	                            _previousEl.remove();
	                            _previousEl = null;
	                        }
	                        if (_currentScope) {
	                            trace_1.trace.traceUiViewEvent("Destroying  (previous) scope", viewData);
	                            _currentScope.$destroy();
	                            _currentScope = null;
	                        }
	                    }
	                    if (currentEl) {
	                        trace_1.trace.traceUiViewEvent("Animate out (previous)", viewData);
	                        renderer.leave(currentEl, function () {
	                            cleanOld();
	                            previousEl = null;
	                        });
	                        previousEl = currentEl;
	                    }
	                    else {
	                        cleanOld();
	                        previousEl = null;
	                    }
	                    currentEl = null;
	                    currentScope = null;
	                }
	                function updateView(config) {
	                    config = config || {};
	                    var newScope = scope.$new();
	                    trace_1.trace.traceUiViewScopeCreated(viewData, newScope);
	                    common_1.extend(viewData, {
	                        context: config.context,
	                        $template: config.template,
	                        $controller: config.controller,
	                        $controllerAs: config.controllerAs,
	                        $locals: config.locals
	                    });
	                    var cloned = $transclude(newScope, function (clone) {
	                        renderer.enter(clone.data('$uiView', viewData), $element, function onUiViewEnter() {
	                            if (currentScope) {
	                                currentScope.$emit('$viewContentAnimationEnded');
	                            }
	                            if (predicates_1.isDefined(autoScrollExp) && !autoScrollExp || scope.$eval(autoScrollExp)) {
	                                $uiViewScroll(clone);
	                            }
	                        });
	                        cleanupLastView();
	                    });
	                    currentEl = cloned;
	                    currentScope = newScope;
	                    currentScope.$emit('$viewContentLoaded', config || viewConfig);
	                    currentScope.$eval(onloadExp);
	                }
	            };
	        }
	    };
	    return directive;
	}
	$ViewDirectiveFill.$inject = ['$compile', '$controller', '$interpolate', '$injector', '$q'];
	function $ViewDirectiveFill($compile, $controller, $interpolate, $injector, $q) {
	    return {
	        restrict: 'ECA',
	        priority: -400,
	        compile: function (tElement) {
	            var initial = tElement.html();
	            return function (scope, $element) {
	                var data = $element.data('$uiView');
	                if (!data)
	                    return;
	                $element.html(data.$template || initial);
	                trace_1.trace.traceUiViewFill(data, $element.html());
	                var link = $compile($element.contents());
	                var controller = data.$controller;
	                var controllerAs = data.$controllerAs;
	                if (controller) {
	                    var locals = data.$locals;
	                    var controllerInstance = $controller(controller, common_1.extend(locals, { $scope: scope, $element: $element }));
	                    if (controllerAs)
	                        scope[controllerAs] = controllerInstance;
	                    $element.data('$ngControllerController', controllerInstance);
	                    $element.children().data('$ngControllerController', controllerInstance);
	                }
	                link(scope);
	            };
	        }
	    };
	}
	angular.module('ui.router.state').directive('uiView', $ViewDirective);
	angular.module('ui.router.state').directive('uiView', $ViewDirectiveFill);
	//# sourceMappingURL=viewDirective.js.map

/***/ },
/* 57 */
/***/ function(module, exports) {

	function $ViewScrollProvider() {
	    var useAnchorScroll = false;
	    this.useAnchorScroll = function () {
	        useAnchorScroll = true;
	    };
	    this.$get = ['$anchorScroll', '$timeout', function ($anchorScroll, $timeout) {
	            if (useAnchorScroll) {
	                return $anchorScroll;
	            }
	            return function ($element) {
	                return $timeout(function () {
	                    $element[0].scrollIntoView();
	                }, 0, false);
	            };
	        }];
	}
	angular.module('ui.router.state').provider('$uiViewScroll', $ViewScrollProvider);
	//# sourceMappingURL=viewScroll.js.map

/***/ }
/******/ ])
});
;