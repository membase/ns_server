$(function () {
  document.title = String(document.title) + " (testing)"
});

var TestingSupervisor = {
  chooseSingle: function (arg, predicate) {
    if (!_.isArray(arg)) {
      var key = this.chooseSingle(_.keys(arg), predicate);
      return arg[key];
    }
    var passing = _.select(arg, function (id) {
      return predicate(id);
    });
    if (passing.length != 1)
      throw new Error("Invalid number of predicate-passing of items: " + passing.length);
    return passing[0];
  },
  chooseVisible: function (arg) {
    return this.chooseSingle(arg, function (id) {
      return $($i(id)).css('display') != 'none';
    });
  },
  chooseSelected: function (arg) {
    return this.chooseSingle(arg, function (id) {
      return $($i(id)).hasClass('selected');
    });
  },
  activeSection: function () {
    return this.chooseVisible(['overview', 'alerts', 'settings']);
  },
  activeGraphZoom: function () {
    return this.chooseSelected({
      'overview_graph_zoom_real_time': 'real_time',
      'overview_graph_zoom_one_hr' : 'one_hr',
      'overview_graph_zoom_day': 'day'
    });
  },
  activeKeysZoom: function () {
    return this.chooseSelected({
      'overview_keys_zoom_real_time': 'real_time',
      'overview_keys_zoom_one_hr' : 'one_hr',
      'overview_keys_zoom_day': 'day'
    });
  },
  activeStatsTarget: function () {
    var cell = DAO.cells.currentStatTargetCell;
    if (!cell)
      return null;
    var value = cell.value;
    if (!cell)
      return null;
    return [value.name, value.stats.uri];
  },
  installInterceptor: function (wrapperName, obj, methodName) {
    var self = this;
    var method = obj[methodName];
    var rv = obj[methodName] = function () {
      var args = [method].concat(_.toArray(arguments));
      return self[wrapperName].apply(self, args);
    }
    rv.originalMethod = method;
    return rv;
  },
  interceptAjax: function () {
    this.installInterceptor('interceptedAjax', $, 'ajax');
  },
  interceptedAjax: function (original, options) {
    console.log("intercepted ajax:", options);
    (new MockedRequest(options)).respond();
  }
};

var MockedRequest = mkClass({
  alertsResponse: {limit: 15,
                   settings: {updateURI: "/alerts/settings"},
                   list: [{number: 3,
                           type: "info",
                           tstamp: 1259836260000,
                           shortText: "Above Average Operations per Second",
                           text: "Licensing, capacity, NorthScale issues, etc."},
                          {number: 2,
                           type: "attention",
                           tstamp: 1259836260000,
                           shortText: "New Node Joined Pool",
                           text: "A new node is now online"},
                          {number: 1,
                           type: "warning",
                           tstamp: 1259836260000,
                           shortText: "Server Node Down",
                           text: "Server node is no longer available"}]},
  initialize: function (options) {
    if (options.type != 'GET' && options.type != 'POST') {
      throw new Error("unknown method: " + options.type);
    }

    this.options = options;

    var url = options.url;
    var hostPrefix = document.location.protocol + ":/" + document.location.host;
    if (url.indexOf(hostPrefix) == 0)
      url = url.substring(hostPrefix);
    if (url.indexOf("/") == 0)
      url = url.substring(1);
    if (url.lastIndexOf("/") == url.length - 1)
      url = url.substring(0, url.length - 1);

    this.url = url;

    var path = url.split("/")
    this.path = path;
  },
  fakeResponse: function (data) {
    var self = this;
    _.defer(function () {
      if (data instanceof Function) {
        data.call(null, fakeResponse);
        return;
      }
      self.options.success(data, 'success');
    });
  },
  respond: function () {
    if (this.options.type == 'GET')
      return this.respondGET();
    return this.respondPOST();
  },
  respondGET: function () {
    var path = this.path;

    var resp;
    if (path[0] == "pools") {
      if (path.length == 1) {
        // /pools
        resp = {pools: [
          {name: 'default',
           uri: "/pools/default"}]};
      } else {
        // /pools/:id
        resp = this.handlePoolDetails();
      }
    } else if (path[0] == "buckets" && path.length == 1) {
      resp = this.handleBucketList();
    } else if (path[0] == 'buckets') {
      if (path.length == 2) {
        // /buckets/:id
        if (path[1] == "5")
          resp = {nodes:[], // not used for now
                  testAppBucket: true,
                  testAppRunning: false,
                  controlURL: "asdasdasdasdasdasd",
                  stats: {uri: "/buckets/5/stats"},
                  name: "Excerciser Application"};
        else
          resp = {nodes: [], // not used for now
                  stats: {uri: "/buckets/4/stats"},
                  name: "default"};
      } else {
        // /buckets/:id/stats
        resp = this.handleStats();
      }
    } else if (path[0] == 'alerts' && path.length == 1) {
      // /alerts
      resp = this.alertsResponse;
    } else {
      throw new Error("Unknown ajax path: " + this.options.url);
    }

    console.log("res is", resp);
    this.fakeResponse(resp);
  },
  respondPOST: function () {
    if (_.isEqual(this.path, ["buckets"])) {
      return this.handleBucketsPost();
    }

    this.fakeResponse('');
  },

  // mostly stolen from MIT-licensed prototypejs.org (String#toQueryParams)
  deserialize: function (dataString) {
    return _.reduce(dataString.split('&'), { }, function(hash, pair) {
      if ((pair = pair.split('='))[0]) {
        var key = decodeURIComponent(pair.shift());
        var value = pair.length > 1 ? pair.join('=') : pair[0];
        if (value != undefined) value = decodeURIComponent(value);

        if (key in hash) {
          if (!_.isArray(hash[key]))
            hash[key] = [hash[key]];
          hash[key].push(value);
        }
        else hash[key] = value;
      }
      return hash;
    });
  },

  handleBucketsPost: function () {
    var self = this;

    var params = this.deserialize(this.options.data)
    console.log("params: ", params);
    var errors = [];
    // check password at UI side
    // if (params['password'] != params['verifyPassword'])
    //   errors.push("passwords don't match");

    if (isBlank(params['name'])) {
      errors.push('name cannot be blank');
    } else if (params['name'] != 'new-name') {
      errors.push('name has already been taken');
    }

    if (!(/^\d*$/.exec(params['cacheSize']))) {
      errors.push("cache size must be integer");
    }

    if (isBlank(params['password'])) {
      errors.push('password cannot be blank');
    }

    if (errors.length) {
      var resp = {errors: errors}
      var fakeXHR = {status: 400};
      _.defer(function () {
        var oldHttpData = $.httpData;
        $.httpData = function () {return resp;}

        try {
          self.options.error(fakeXHR, 'error');
        } finally {
          $.httpData = oldHttpData;
        }
      });
      return;
    }

    self.fakeResponse('');
  },

  handlePoolDetails: function () {
    return {nodes: [{hostname: "mickey-mouse.disney.com",
                     status: "healthy",
                     ports: {proxy: 11211,
                             direct: 11311},
                     otp_node: "ns1@mickey-mouse.disney.com",
                     otp_cookie: "SADFDFGDFG"},
                    {hostname: "donald-duck.disney.com",
                     status: "healthy",
                     ports: {proxy: 11211,
                             direct: 11311},
                     otp_node: "ns1@donald-duck.disney.com",
                     otp_cookie: "SADFDFGDFG"},
                    {hostname: "goofy.disney.com",
                     status: "healthy",
                     ports: {proxy: 11211,
                             direct: 11311},
                     otp_node: "ns1@goofy.disney.com",
                     otp_cookie: "SADFDFGDFG"}],
            buckets: {
              // GET returns first page of bucket details with link to next page
              uri: "/buckets",
              // returns just names and uris, but complete (i.e. without pagination)
              shallowList: "/buckets?shallow=true"
            },
            stats: {uri: "/buckets/4/stats?really_for_pool=1"},
            name: "Default Pool"}
  },
  handleBucketList: function () {
    return [{name: "default",
             uri: "/buckets/4",
             flushCacheURI: "/buckets/4/flush",
             passwordURI: "/buckets/4/password",
             basicStats: {
               cacheSize: 64, // in megs
               opsPerSec: 100,
               evictionsPerSec: 5,
               cachePercentUsed: 50
             }},
            {name: "Excerciser Application",
             uri: "/buckets/5",
             testAppBucket: true,
             testAppRunning: false,
             testAppStatusURI: "/testappuri",
             flushCacheURI: "/buckets/5/flush",
             passwordURI: "/buckets/5/password",
             basicStats: {
               cacheSize: 65, // in megs
               opsPerSec: 101,
               evictionsPerSec: 6,
               cachePercentUsed: 51
             }},
            {name: "new-year-site",
             uri: "/buckets/6",
             flushCacheURI: "/buckets/6/flush",
             passwordURI: "/buckets/6/password",
             basicStats: {
               cacheSize: 66, // in megs
               opsPerSec: 102,
               evictionsPerSec: 7,
               cachePercentUsed: 52
             }},
            {name: "new-year-site-staging",
             uri: "/buckets/7",
             flushCacheURI: "/buckets/7/flush",
             passwordURI: "/buckets/7/password",
             basicStats: {
               cacheSize: 67, // in megs
               opsPerSec: 103,
               evictionsPerSec: 8,
               cachePercentUsed: 53
             }}]
  },
  handleStats: function () {
    var params = this.options['data'];
    var opsPerSecondZoom = params['opsPerSecondZoom'] || "now";
    var allSamples = {
      '1hr': {"gets":[3,14,23,52,45,25,23,22,50,67,59,55,54,41,36,35,26,61,72,49,60],
              "misses":[23,14,45,64,41,45,43,25,14,11,18,36,64,76,86,86,79,78,55,59,49],
              "sets":[42,65,42,63,81,87,74,84,56,44,71,64,49,48,55,46,37,46,64,33,18],
              "ops":[61,65,64,75,77,57,68,76,64,61,66,63,68,37,32,60,72,54,43,41,55]},
      'now': {"gets":[70,44,28,17,29,61,70,47,39,47,27,54,47,30,43,45,65,49,46,41,62],
              "misses":[67,48,45,29,18,53,57,59,78,57,41,41,29,34,34,43,51,58,63,71,78],
              "sets":[65,51,61,42,58,71,55,77,69,44,43,22,59,63,36,46,40,69,80,50,69],
              "ops":[63,55,27,30,35,57,39,38,32,17,38,49,61,78,82,71,41,35,25,44,68]},
      '24hr': {"gets":[69,56,57,61,58,55,74,87,93,88,55,69,56,67,81,65,40,58,47,43,30],
               "misses":[14,45,56,45,42,43,29,23,47,23,40,60,45,54,64,40,28,19,59,48,60],
               "sets":[60,34,54,30,26,30,34,35,38,27,59,67,43,45,48,66,42,43,52,44,35],
               "ops":[6,24,53,64,35,30,45,50,31,32,29,50,28,30,30,40,30,54,39,37,58]}};
    var samples = allSamples[opsPerSecondZoom];
    var samplesSize = samples["gets"].length;

    var samplesInterval = 5000;
    if (opsPerSecondZoom == "24hr")
      samplesInterval = 86400000 / samplesSize;
    else if (opsPerSecondZoom == "1hr")
      samplesInterval = 3600000 / samplesSize;

    var now = (new Date()).valueOf();
    var lastSampleTstamp = now;

    if (samplesInterval == 5000) {
      var rotates = ((now / 1000) >> 0) % samplesSize;
      var newSamples = {};
      for (var k in samples) {
        var data = samples[k];
        newSamples[k] = data.concat(data).slice(rotates, rotates + samplesSize);
      }
      samples = newSamples;
    }

    var startTstampParam = params["opsbysecondStartTStamp"];
    if (startTstampParam !== undefined) {
      var startTstamp = parseInt(startTstampParam, 10);

      var intervals = Math.floor((now - startTstampParam) / samplesInterval);
      if (intervals > samplesSize) {
        throw new Error("should not happen");
      }
      lastSampleTstamp = startTstamp + intervals * samplesInterval;

      var newSamples = {};
      for (var k in samples) {
        var data = samples[k];
        newSamples[k] = data.slice(-intervals);
      }
      samples = newSamples;
    }

    return {hot_keys: [{name: "user:image:value",
                        gets: 10000,
                        bucket: "Excerciser application",
                        misses: 100,
                        type: "Persistent"},
                       {name: "user:image:value2",
                        gets: 10000,
                        bucket: "Excerciser application",
                        misses: 100,
                        type: "Cache"},
                       {name: "user:image:value3",
                        gets: 10000,
                        bucket: "Excerciser application",
                        misses: 100,
                        type: "Persistent"},
                       {name: "user:image:value4",
                        gets: 10000,
                        bucket: "Excerciser application",
                        misses: 100,
                        type: "Cache"}],
            op: _.extend({tstamp: lastSampleTstamp,
                          'samplesInterval': samplesInterval},
                         samples)};
  }
});

TestingSupervisor.interceptAjax();
