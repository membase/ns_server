Math.Ki = 1024;
Math.Mi = 1048576;
Math.Gi = 1073741824;

angular.module('mnFilters', [])

  .filter('mnCount', function () {
    return function (count, text) {
      if (count == null) {
        return '?' + text + '(s)';
      }
      count = Number(count);
      if (count > 1) {
        var lastWord = text.split(/\s+/).slice(-1)[0];
        var specialPluralizations = {
          'copy': 'copies'
        };
        var specialCase = specialPluralizations[lastWord];
        if (specialCase) {
          text = specialCase;
        } else {
          text += 's';
        }
      }
      return [String(count), ' ', text].join('');
    };
  })

  .filter('mnCloneOnlyData', function () {
    return function (data) {
      return JSON.parse(JSON.stringify(data));
    };
  })

  .filter('mnParseHttpDate', function () {
    var rfc1123RE = /^\s*[a-zA-Z]+, ([0-9][0-9]) ([a-zA-Z]+) ([0-9]{4,4}) ([0-9]{2,2}):([0-9]{2,2}):([0-9]{2,2}) GMT\s*$/m;
    var rfc850RE = /^\s*[a-zA-Z]+, ([0-9][0-9])-([a-zA-Z]+)-([0-9]{2,2}) ([0-9]{2,2}):([0-9]{2,2}):([0-9]{2,2}) GMT\s*$/m;
    var asctimeRE = /^\s*[a-zA-Z]+ ([a-zA-Z]+) ((?:[0-9]| )[0-9]) ([0-9]{2,2}):([0-9]{2,2}):([0-9]{2,2}) ([0-9]{4,4})\s*$/m;

    var monthDict = {};

    (function () {
      var monthNames = ["January", "February", "March", "April", "May", "June",
                        "July", "August", "September", "October", "November", "December"];

      for (var i = monthNames.length-1; i >= 0; i--) {
        var name = monthNames[i];
        var shortName = name.substring(0, 3);
        monthDict[name] = i;
        monthDict[shortName] = i;
      }
    })();

    var badDateException;
    (function () {
      try {
        throw {};
      } catch (e) {
        badDateException = e;
      }
    })();
    function parseMonth(month) {
      var number = monthDict[month];
      if (number === undefined)
        throw badDateException;
      return number;
    }

    function doParseHTTPDate(date) {
      var match;
      if ((match = rfc1123RE.exec(date)) || (match = rfc850RE.exec(date))) {
        var day = parseInt(match[1], 10);
        var month = parseMonth(match[2]);
        var year = parseInt(match[3], 10);

        var hour = parseInt(match[4], 10);
        var minute = parseInt(match[5], 10);
        var second = parseInt(match[6], 10);

        return new Date(Date.UTC(year, month, day, hour, minute, second));
      } else if ((match = asctimeRE.exec(date))) {
        var month = parseMonth(match[1]);
        var day = parseInt(match[2], 10);

        var hour = parseInt(match[3], 10);
        var minute = parseInt(match[4], 10);
        var second = parseInt(match[5], 10);

        var year = parseInt(match[6], 10);

        return new Date(Date.UTC(year, month, day, hour, minute, second));
      } else {
        throw badDateException;
      }
    }

    return function (date, badDate) {
      try {
        return doParseHTTPDate(date);
      } catch (e) {
        if (e === badDateException) {
          return badDate || (new Date());
        }
        throw e;
      }
    }
  })

  .filter('mnPrepareQuantity', function () {
    return function (value, K) {
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
    };
  })

  .filter('mnCalculatePercent', function () {
    return function (value, total) {
      return (value * 100 / total) >> 0;
    };
  })

  .filter('mnEllipsisiseOnLeft', function () {
    return function (text, length) {
      if (length <= 3) {
        // asking for stupidly short length will cause this to do
        // nothing
        return text;
      }
      if (text.length > length) {
        return "..." + text.slice(3-length);
      }
      return text;
    };
  })

  .filter('mnRescaleForSum', function () {
    // proportionaly rescales values so that their sum is equal to given
    // number. Output values need to be integers. This particular
    // algorithm tries to minimize total rounding error. The basic approach
    // is same as in Brasenham line/circle drawing algorithm.
    return function (newSum, values, oldSum) {
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
    };
  })

  .filter('mnNaturalSorting', function () {
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

    return function (collection, valueTransformer) {
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
    };
  })

  .filter('mnMakeSafeForCSS', function () {
    return function (name) {
      return name.replace(/[^a-z0-9]/g, function (s) {
        var c = s.charCodeAt(0);
        if (c == 32) return '-';
        if (c >= 65 && c <= 90) return '_' + s.toLowerCase();
        return '__' + ('000' + c.toString(16)).slice(-4);
      });
    };
  })

  .filter('mnStripPortHTML', function () {
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
  })

  .filter('mnTruncateTo3Digits', function () {
    return function (value, leastScale, roundMethod) {
      if (!value) {
        return 0;
      }
      var scale = _.detect([100, 10, 1, 0.1, 0.01, 0.001], function (v) {return value >= v;}) || 0.0001;
      if (leastScale != undefined && leastScale > scale) {
        scale = leastScale;
      }
      scale = 100 / scale;
      return Math[roundMethod || "round"](value*scale)/scale;
    };
  })

  .filter('mnFormatQuantity', function (mnPrepareQuantityFilter, mnTruncateTo3DigitsFilter) {
    return function (value, numberSystem, spacing) {
      if (!value && !_.isNumber(value)) {
        return value;
      }
      if (spacing == null) {
        spacing = '';
      }
      if (numberSystem === 1000 && value <= 9999 && value % 1 === 0) { // MB-11784
        return value;
      }

      var t = mnPrepareQuantityFilter(value, numberSystem);
      return [mnTruncateTo3DigitsFilter(value/t[0], undefined, "floor"), spacing, t[1]].join('');
    };
  })

  .filter('mnFormatMemSize', function (mnFormatQuantityFilter) {
    return function (value) {
      return mnFormatQuantityFilter(value, null, ' ');
    };
  })

  .filter('mnFormatUptime', function () {
    return function (seconds, precision) {
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
    };
  })

  .filter('mnMBtoBytes', function () {
    return function (MB) {
      return MB * Math.Mi;
    };
  })

  .filter('mnBytesToMB', function () {
    return function (bytes) {
      return Math.floor(bytes / Math.Mi);
    };
  })

  .filter('parseVersion', function () {
    return function (str) {
      if (!str) {
        return;
      }
      // Expected string format:
      //   {release version}-{build #}-{Release type or SHA}-{enterprise / community}
      // Example: "1.8.0-9-ga083a1e-enterprise"
      var a = str.split(/[-_]/);
      if (a.length === 3) {
        // Example: "1.8.0-9-enterprise"
        //   {release version}-{build #}-{enterprise / community}
        a.splice(2, 0, undefined);
      }
      a[0] = (a[0].match(/[0-9]+\.[0-9]+\.[0-9]+/) || ["0.0.0"])[0];
      a[1] = a[1] || "0";
      // a[2] = a[2] || "unknown";
      // We append the build # to the release version when we display in the UI so that
      // customers think of the build # as a descriptive piece of the version they're
      // running (which in the case of maintenance packs and one-off's, it is.)
      a[0] = a[0] + "-" + a[1];
      a[3] = (a[3] && (a[3].substr(0, 1).toUpperCase() + a[3].substr(1))) || "DEV";
      return a; // Example result: ["1.8.0-9", "9", "ga083a1e", "Enterprise"]
    }
  })

  .filter('getStringBytes', function () {
    return function (countMe) {
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
  })

  .filter('mnFormatServices', function () {
    return function (service) {
      switch (service) {
        case 'kv': return 'Data';
        case 'n1ql': return 'Query';
        case 'index': return 'Index';
      }
    }
  })

  .filter('mnPrettyVersion', function (parseVersionFilter) {

    return function (str, full) {
      if (!str) {
        return;
      }
      var a = parseVersionFilter(str);
      // Example default result: "1.8.0-7 Enterprise Edition (build-7)"
      // Example full result: "1.8.0-7 Enterprise Edition (build-7-g35c9cdd)"
      var suffix = "";
      if (full && a[2]) {
        suffix = '-' + a[2];
      }
      return [a[0], a[3], "Edition", "(build-" + a[1] + suffix + ")"].join(' ');
    };
  })

  .filter('encodeURIComponent', function () {
    return encodeURIComponent;
  });
