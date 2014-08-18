(function (_) {
  Math.Ki = 1024;
  Math.Mi = 1048576;
  Math.Gi = 1073741824;

  function MBtoBytes(MB) {
    return MB * Math.Mi;
  }

  function bytesToMB(bytes) {
    return Math.floor(bytes / Math.Mi);
  }

  function getStringBytes(countMe) {
    if (!_.isString(countMe)) {
      return 0;
    }
    var escapedStr = encodeURI(countMe);
    var escapedStrLength = escapedStr.length;

    if (escapedStr.indexOf("%") != -1) {
      var count = escapedStr.split("%").length - 1 || 1;
      return count + (escapedStrLength - (count * 3));
    } else {
      return escapedStrLength;
    }
  }

  // This is an atered version of the jQuery.param()
  // https://github.com/jquery/jquery/blob/master/src/serialize.js
  function serializeData(data) {
    if (!angular.isObject(data)) {
      return data == null ? "" : data.toString();
    }
    var rv = [];
    var name;
    for (name in data) {
      if (data.hasOwnProperty(name)) {
        var value = data[name];
        rv.push(encodeURIComponent(name) + "=" + encodeURIComponent(value == null ? "" : value));
      }
    }

    return rv.sort().join("&").replace(/%20/g, "+");
  }

  function formatMemSize(value) {
    return formatQuantity(value, null, ' ');
  }

  var maybeStripPort = (function () {
    var cachedAllServers;
    var cachedIsStripping;
    var strippingRE = /:8091$/;

    return function (value, allServers) {
      if (allServers === undefined) {
        throw new Error("second argument is required!");
      }
      if (cachedAllServers === allServers) {
        var isStripping = cachedIsStripping;
      } else {
        if (allServers.length == 0 || _.isString(allServers[0])) {
          var allNames = allServers;
        } else {
          var allNames = _.pluck(allServers, 'hostname');
        }
        var isStripping = _.all(allNames, function (h) {return h.match(strippingRE);});
        cachedIsStripping = isStripping;
        cachedAllServers = allServers;
      }
      if (isStripping) {
        var match = value.match(strippingRE);
        return match ? value.slice(0, match.index) : value;
      }
      return value;
    };
  })();

  function formatUptime(seconds, precision) {
    precision = precision || 8;

    var arr = [[86400, "days", "day"],
               [3600, "hours", "hour"],
               [60, "minutes", "minute"],
               [1, "seconds", "second"]];

    var rv = [];

    _.each(arr, function (item) {
      var period = item[0];
      var value = (seconds / period) >> 0;
      seconds -= value * period;
      if (value) {
        rv.push(String(value) + ' ' + (value > 1 ? item[1] : item[2]));
      }
      return !!--precision;
    });
    return rv.join(', ');
  }

  function prepareQuantity(value, K) {
    K = K || 1024;

    var M = K*K;
    var G = M*K;
    var T = G*K;

    if (K !== 1024 && K !== 1000) {
      throw new Error("Unknown number system");
    }

    var t = _.detect([[T,'T'],[G,'G'],[M,'M'],[K,'K']], function (t) {
      return value >= t[0];
    }) || [1, ''];

    if (K === 1024) {
      t[1] += 'B';
    }

    return t;
  }
  function formatQuantity(value, numberSystem, spacing) {
    if (!value) {
      return value;
    }
    if (spacing == null) {
      spacing = '';
    }
    if (numberSystem === 1000 && value <= 9999 && value % 1 === 0) { // MB-11784
      return value;
    }

    var t = prepareQuantity(value, numberSystem);
    return [truncateTo3Digits(value/t[0], undefined, "floor"), spacing, t[1]].join('');
  }
  function stripPortHTML(value, allServers) {
    return maybeStripPort(value, allServers)
  }
  function truncateTo3Digits(value, leastScale, roundMethod) {
    var scale = _.detect([100, 10, 1, 0.1, 0.01, 0.001], function (v) {return value >= v;}) || 0.0001;
    if (leastScale != undefined && leastScale > scale) {
      scale = leastScale;
    }
    scale = 100 / scale;
    return Math[roundMethod || "round"](value*scale)/scale;
  }
  function makeSafeForCSS(name) {
    return name.replace(/[^a-z0-9]/g, function(s) {
      var c = s.charCodeAt(0);
      if (c == 32) return '-';
      if (c >= 65 && c <= 90) return '_' + s.toLowerCase();
      return '__' + ('000' + c.toString(16)).slice(-4);
    });
  }
  function naturalSorting(collection, valueTransformer) {
    if (!_.isArray(collection)) {
      return;
    }
    var valueTransformerType = typeof valueTransformer;
    var originValueTransformer = valueTransformer;
    function mayBeDot(value) {
      return valueTransformerType === 'string' ? value[originValueTransformer] : value;
    }
    function defaultValueTransformer(natural, a, b) {
      return natural(mayBeDot(a), mayBeDot(b));
    }

    valueTransformer = _.partial(
      valueTransformerType === 'function' ? originValueTransformer : defaultValueTransformer
    , naturalSort);

    collection.sort(valueTransformer);

    return collection;
  }
  /*
   * Natural Sort algorithm for Javascript - Version 0.6 - Released under MIT license
   * Author: Jim Palmer (based on chunking idea from Dave Koelle)
   * Contributors: Mike Grier (mgrier.com), Clint Priest, Kyle Adams, guillermo
   *
   * Alterations: removed date and hex parsing/sorting
   */
  function naturalSort(a, b) {
    var re = /(^-?[0-9]+(\.?[0-9]*)[df]?e?[0-9]?$|^0x[0-9a-f]+$|[0-9]+)/gi,
      sre = /(^[ ]*|[ ]*$)/g,
      ore = /^0/,
      // convert all to strings and trim()
      x = a.toString().replace(sre, '') || '',
      y = b.toString().replace(sre, '') || '',
      // chunk/tokenize
      xN = x.replace(re, '\0$1\0').replace(/\0$/,'').replace(/^\0/,'').split('\0'),
      yN = y.replace(re, '\0$1\0').replace(/\0$/,'').replace(/^\0/,'').split('\0');
    // natural sorting through split numeric strings and default strings
    for(var cLoc=0, numS=Math.max(xN.length, yN.length); cLoc < numS; cLoc++) {
      // find floats not starting with '0', string or 0 if not defined (Clint Priest)
      oFxNcL = !(xN[cLoc] || '').match(ore) && parseFloat(xN[cLoc]) || xN[cLoc] || 0;
      oFyNcL = !(yN[cLoc] || '').match(ore) && parseFloat(yN[cLoc]) || yN[cLoc] || 0;
      // handle numeric vs string comparison - number < string - (Kyle Adams)
      if (isNaN(oFxNcL) !== isNaN(oFyNcL)) return (isNaN(oFxNcL)) ? 1 : -1;
      // rely on string comparison if different types - i.e. '02' < 2 != '02' < '2'
      else if (typeof oFxNcL !== typeof oFyNcL) {
        oFxNcL += '';
        oFyNcL += '';
      }
      if (oFxNcL < oFyNcL) return -1;
      if (oFxNcL > oFyNcL) return 1;
    }
    return 0;
  }

  // proportionaly rescales values so that their sum is equal to given
  // number. Output values need to be integers. This particular
  // algorithm tries to minimize total rounding error. The basic approach
  // is same as in Brasenham line/circle drawing algorithm.
  function rescaleForSum(newSum, values, oldSum) {
    if (oldSum == null) {
      oldSum = _.inject(values, function (a,v) {return a+v;}, 0);
    }
    // every value needs to be multiplied by newSum / oldSum
    var error = 0;
    var outputValues = new Array(values.length);
    for (var i = 0; i < outputValues.length; i++) {
      var v = values[i];
      v *= newSum;
      v += error;
      error = v % oldSum;
      outputValues[i] = Math.floor(v / oldSum);
    }
    return outputValues;
  }

  function calculatePercent(value, total) {
    return (value * 100 / total) >> 0;
  }

  function ellipsisiseOnLeft(text, length) {
    if (length <= 3) {
      // asking for stupidly short length will cause this to do
      // nothing
      return text;
    }
    if (text.length > length) {
      return "..." + text.slice(3-length);
    }
    return text;
  }

  function wrapToArray(value) {
    return value ? _.isArray(value) ? value : [value] : [];
  }

  function createApplyToScope(scope) {
    return function applyToScope(name) {
      return function doApplyToScope(value) {
        scope[name] = value;
      }
    }
  }

  var specialPluralizations = {
    'copy': 'copies'
  };

  function count(count, text) {
    if (count == null) {
      return '?' + text + '(s)';
    }
    count = Number(count);
    if (count > 1) {
      var lastWord = text.split(/\s+/).slice(-1)[0];
      var specialCase = specialPluralizations[lastWord];
      if (specialCase) {
        text = specialCase;
      } else {
        text += 's';
      }
    }
    return [String(count), ' ', text].join('');
  }

  _.mixin({ 'count': count});
  _.mixin({ 'serializeData': serializeData});
  _.mixin({ 'createApplyToScope': createApplyToScope});
  _.mixin({ 'MBtoBytes': MBtoBytes});
  _.mixin({ 'bytesToMB': bytesToMB});
  _.mixin({ 'getStringBytes': getStringBytes});
  _.mixin({ 'wrapToArray': wrapToArray})
  _.mixin({ 'calculatePercent': calculatePercent});
  _.mixin({ 'ellipsisiseOnLeft': ellipsisiseOnLeft});
  _.mixin({ 'rescaleForSum': rescaleForSum});
  _.mixin({ 'naturalSorting': naturalSorting });
  _.mixin({ 'makeSafeForCSS': makeSafeForCSS });
  _.mixin({ 'stripPortHTML': stripPortHTML });
  _.mixin({ 'truncateTo3Digits': truncateTo3Digits });
  _.mixin({ 'formatQuantity': formatQuantity });
  _.mixin({ 'formatMemSize': formatMemSize });
  _.mixin({ 'formatUptime': formatUptime });
})(_);
