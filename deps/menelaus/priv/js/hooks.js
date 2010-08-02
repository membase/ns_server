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
    this.installInterceptor('interceptedAddBasicAuth', window, 'addBasicAuth');
  },
  interceptedAjax: function (original, options) {
    console.log("intercepted ajax:", options.url, options);
    (new MockedRequest(options)).respond();
  },
  interceptedAddBasicAuth: function (original, xhr, login, password) {
    if (!xhr.fakeAddBasicAuth) {
      throw new Error("incomplete hook.js installation");
    }
    xhr.fakeAddBasicAuth(login, password);
  }
};

var ajaxRespondDelay = 100;

// mostly stolen from MIT-licensed prototypejs.org (String#toQueryParams)
function deserializeQueryString(dataString) {
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
  })
}

var MockedRequest = mkClass({
  initialize: function (options) {
    if (options.type != 'GET' && options.type != 'POST' && options.type != 'DELETE') {
      throw new Error("unknown method: " + options.type);
    }

    this.options = options;

    this.fakeXHR = {
      requestHeaders: [],
      setRequestHeader: function () {
        this.requestHeaders.push(_.toArray(arguments));
      },
      fakeAddBasicAuth: function (login, password) {
        this.login = login;
        this.password = password;
      }
    }

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

    // we modify that list in place in few actions
    this.bucketsList = this.findResponseFor('GET', ['pools', 'default', 'buckets']);
  },
  fakeResponse: function (data) {
    if (data instanceof Function) {
      data.call(null, fakeResponse);
      return;
    }
    console.log("responded with: ", data);
    this.responded = true;
    if (this.options.success)
      this.options.success(data, 'success');
  },
  authError: (function () {
    try {
      throw new Error("autherror")
    } catch (e) {
      return e;
    }
  })(),
  respond: function () {
    if  (this.options.url.indexOf("&etag") > 0) {
      setTimeout($m(this, 'respondForReal'), 5000);
    } else if (this.options.async != false)
      setTimeout($m(this, 'respondForReal'), window.ajaxRespondDelay);
    else
      this.respondForReal();
  },
  findResponseFor: function (method, path, body) {
    var x = this.routes.x;
    var foundResp;
    var routeArgs;
    _.each(this.routes, function (rt) {
      var key = rt[0];
      if (key[0] != method)
        return;
      var pattern = key[1];
      if (pattern.length != path.length)
        return;
      var args = [];
      for (var i = pattern.length-1; i >= 0; i--) {
        var value = pattern[i];
        if (value == x)
          args.push(path[i]);
        else if (value != path[i])
          return;
      }
      foundResp = rt[1];
      if (rt[2])
        foundResp = rt[2].apply(this, [foundResp].concat(args));
      routeArgs = args;
      _.breakLoop();
    });
    if (body)
      return body.call(this, foundResp, routeArgs);
    return foundResp;
  },
  executeRouteResponse: function (foundResp, routeArgs) {
    if (_.isFunction(foundResp)) {
      if (functionArgumentNames(foundResp)[0] == "$data")
        routeArgs.unshift(this.deserialize());
      foundResp = foundResp.apply(this, routeArgs);
      if (this.responded)
        return;
      if (foundResp == null)
        foundResp = "";
    }
    return _.clone(foundResp);
  },
  respondForReal: function () {
    if ($.ajaxSettings.beforeSend)
      $.ajaxSettings.beforeSend(this.fakeXHR);

    this.findResponseFor(this.options.type, this.path, function (foundResp, routeArgs) {
      if (!foundResp) {
        console.log("Bad request is: ", this);
        throw new Error("Unknown ajax request: Method: " + this.options.type + ", Path: " + this.options.url);
      }

      try {
        this.checkAuth();
        foundResp = this.executeRouteResponse(foundResp, routeArgs);
        if (!this.responded && !this.responseDelayed)
          this.fakeResponse(foundResp);
      } catch (e) {
        if (e !== this.authError) {
          throw e;
        }

        this.fakeXHR.status = 401;
        // auth error
        if (this.options.error) {
          this.options.error(this.fakeXHR, 'error');
        } else
          $.ajaxSettings.error(this.fakeXHR, 'error');
      }
    });
  },
  checkAuth: function () {
  },
  checkAuthReal: function () {
    if (this.fakeXHR.login != 'admin' || this.fakeXHR.password != 'admin')
      throw this.authError;
  },

  deserialize: function (data) {
    data = data || this.options.data;
    return deserializeQueryString(data);
  },

  errorResponse: function (resp) {
    var self = this;
    self.responded = true;
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
  },

  handleBucketsPost: function () {
    var self = this;

    var params = this.deserialize()
    console.log("params: ", params);
    var errors = [];

    if (isBlank(params['name'])) {
      errors.push('name cannot be blank');
    } else if (params['name'] != 'new-name') {
      errors.push('name has already been taken');
    }

    if (!(/^\d*$/.exec(params['cacheSize']))) {
      errors.push("cache size must be an integer");
    }

    if (errors.length) {
      return self.errorResponse(errors);
    }

    self.fakeResponse('');
  },

  handleJoinCluster: function () {
    var params = this.deserialize()
    console.log("params: ", params);
    var ok = true;

    _.each(('clusterMemberHostIp clusterMemberPort user password').split(' '), function (name) {
      if (!params[name] || !params[name].length) {
        ok = false;
      }
    });

    if (ok) {
      MockedRequest.globalData.initValue = 'done'
      this.fakeResponse('');
    } else
      this.errorResponse(['error1', 'error2']);
  },

  handleWorkloadControlPost: function () {
    var params = this.deserialize()
    if (params['onOrOff'] == 'on') {
      this.bucketsList[1].status = true;
    } else {
      this.bucketsList[1].status = false;
    }

    return this.fakeResponse('');
  },
  handleBucketRemoval: function () {
    var self = this;

    var bucket = _.detect(self.bucketsList, function (b) {
      return b.uri == self.options.url;
    });
    console.log("deleting bucket: ", bucket);

    MockedRequest.prototype.bucketsList = _.without(self.bucketsList, bucket);

    return this.fakeResponse('');
  },
  handleStats: function () {
    var params = this.options['data'];
    var zoom = params['zoom'] || 'minute'
    var samplesSelection = [[3,14,23,52,45,25,23,22,50,67,59,55,54,41,36,35,26,61,72,49,60,52,45,25,23,22,50,67,59,55,14,23,52,45,25,23,22,50,67,59,55,54,41,36,35,26,61,72,49,60,52,45,25,23,22,50,67,59,55],
                            [23,14,45,64,41,45,43,25,14,11,18,36,64,76,86,86,79,78,55,59,49,52,45,25,23,22,50,67,59,55,14,45,64,41,45,43,25,14,11,18,36,64,76,86,86,79,78,55,59,49,52,45,25,23,22,50,67,59,55],
                            [42,65,42,63,81,87,74,84,56,44,71,64,49,48,55,46,37,46,64,33,18,52,45,25,23,22,50,67,59,55,65,42,63,81,87,74,84,56,44,71,64,49,48,55,46,37,46,64,33,18,52,45,25,23,22,50,67,59,55],
                            [61,65,64,75,77,57,68,76,64,61,66,63,68,37,32,60,72,54,43,41,55,52,45,25,23,22,50,67,59,55,65,64,75,77,57,68,76,64,61,66,63,68,37,32,60,72,54,43,41,55,52,45,25,23,22,50,67,59,55]];
    var samples = {};
    for (var idx in StatGraphs.recognizedStats) {
      var data = samplesSelection[(idx + zoom.charCodeAt(0))%4];
      samples[StatGraphs.recognizedStats[idx]] = _.map(data, function (i) {return i*10E9});
    }
    var samplesSize = samplesSelection[0].length;

    var samplesInterval = 1000;

    switch (zoom) {
    case 'hour':
      samplesInterval = 60000;
      break;
    case 'day':
      samplesInterval = 1440000;
    }

    var now = (new Date()).valueOf();
    var base = (new Date(2010, 1, 1)).valueOf();
    var lastSampleTstamp = Math.ceil((now - base) / 1000) * 1000;

    if (samplesInterval == 1000) {
      var rotates = ((now / 1000) >> 0) % samplesSize;
      var newSamples = {};
      for (var k in samples) {
        var data = samples[k];
        newSamples[k] = data.concat(data).slice(rotates, rotates + samplesSize);
      }
      samples = newSamples;
    }

    samples.timestamp = _.range(lastSampleTstamp - samplesSelection[0].length * samplesInterval, lastSampleTstamp, samplesInterval);

    var lastSampleT = params['haveTStamp']
    if (lastSampleT) {
      lastSampleT = parseInt(lastSampleT, 10);
      var index = _.lastIndexOf(samples.timestamp, lastSampleT);
      if (index == samples.timestamp.length-1) {
        var self = this;
        _.delay(function () {
          self.fakeResponse(self.handleStats());
        }, 1000);
        this.responseDelayed = true;
        return;
      }
      if (index >= 0) {
        for (var statName in samples) {
          samples[statName] = samples[statName].slice(index+1);
        }
      }
    }

    return {hot_keys: [{name: "user:image:value",
                        ops: 10000,
                        evictions: 10,
                        ratio: 0.89,
                        bucket: "Excerciser application"},
                       {name: "user:image:value2",
                        ops: 10000,
                        ratio: 0.90,
                        evictions: 11,
                        bucket: "Excerciser application"},
                       {name: "user:image:value3",
                        ops: 10000,
                        ratio: 0.91,
                        evictions: 12,
                        bucket: "Excerciser application"},
                       {name: "user:image:value4",
                        ops: 10000,
                        ratio: 0.92,
                        evictions: 13,
                        bucket: "Excerciser application"}],
            op: {
              lastTStamp: samples.timestamp.slice(-1)[0],
              tstampParam: lastSampleT,
              interval: samplesInterval,
              samplesCount: 60,
              samples: samples
            }};
  },
  __defineRouting: function () {
    var x = {}
    function mkHTTPMethod(method) {
      return function () {
        return [method, _.toArray(arguments)];
      }
    }

    var get = mkHTTPMethod("GET");
    var post = mkHTTPMethod("POST");
    var del = mkHTTPMethod("DELETE");
    function method(name) {
      return function () {
        return this[name].apply(this, arguments);
      }
    }

    // for optional params
    function opt(name) {
      name = new String(name);
      name.__opt = true;
      return name;
    }

    function expectParams() {
      var expectedParams = _.toArray(arguments);

      var chainedRoute = expectedParams[0];
      if (!_.isString(chainedRoute))
        expectedParams.shift();
      else
        chainedRoute = null;

      var mustParams = [], optionalParams = [];
      _.each(expectedParams, function (p) {
        if (p.__opt)
          optionalParams.push(p.valueOf());
        else
          mustParams.push(p);
      });

      var difference = function (a, b) {
        return _.reject(a, function (e) {
          return _.include(b, e);
        });
      }

      return function () {
        var params = this.deserialize();
        var keys = _.keys(params);

        var missingParams = difference(mustParams, keys);
        if (missingParams.length) {
          var msg = "Missing required parameter(s): " + missingParams.join(', ');
          alert("hooks.js: " + msg);
          throw new Error(msg);
        }

        var unexpectedParams = difference(difference(keys, mustParams), optionalParams);
        if (unexpectedParams.length) {
          var msg = "Post has unexpected parameter(s): " + unexpectedParams.join(', ');
          alert("hooks.js: " + msg);
          throw new Error(msg);
        }

        if (chainedRoute)
          return this.executeRouteResponse(chainedRoute, _.toArray(arguments));
      }
    }

    var rv = [
      [post("logClientError"), method('doNothingPOST')],
      [get("logs"), {list: [{type: "info", code: 1, module: "ns_config_log", tstamp: 1265358398000, shortText: "message", text: "config changed"},
                            {type: "info", code: 1, module: "ns_node_disco", tstamp: 1265358398000, shortText: "message", text: "otp cookie generated: bloeahcdnsddpotx"},
                            {type: "info", code: 1, module: "ns_config_log", tstamp: 1265358398000, shortText: "message", text: "config changed"},
                            {type: "info", code: 1, module: "ns_config_log", tstamp: 1265358399000, shortText: "message", text: "config changed"}]}],
      [get("alerts"), {limit: 15,
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
                               text: "Server node is no longer available"}]}],


      [get("settings", "web"), {port:8080,
                                username:"admin",
                                password:""}],
      [get("settings", "advanced"), {alerts: {email:"alk@tut.by",
                                              sender: "alk@tut.by",
                                              email_server: {user:"",
                                                             pass:"",
                                                             addr:"",
                                                             port:"",
                                                             encrypt:"0"},
                                              sendAlerts:"0",
                                              alerts: {
                                                server_down:"1",
                                                server_unresponsive:"1",
                                                server_up:"1",
                                                server_joined:"1",
                                                server_left:"1",
                                                bucket_created:"0",
                                                bucket_deleted:"1",
                                                bucket_auth_failed:"1"}},
                                     ports:{proxyPort:11213,
                                            directPort:11212}}],

      [get("pools"), function () {
        return {implementationVersion: 'only-web.rb-unknown',
                componentsVersion: {
                  "ns_server": "asdasd"
                },
                initStatus: MockedRequest.globalData.initValue,
                pools: [
                  {name: 'default',
                   uri: "/pools/default"}]}
      }],
      [get("pools", x), {nodes: [{hostname: "mickey-mouse.disney.com",
                                  status: "healthy",
                                  clusterMembership: "inactiveAdded",
                                  os: 'Linux',
                                  version: 'only-web.rb',
                                  uptime: 86400,
                                  ports: {proxy: 11211,
                                          direct: 11311},
                                  memoryTotal: 2032574464,
                                  memoryFree: 1589864960,
                                  mcdMemoryReserved: 2032574464,
                                  mcdMemoryAllocated: 89864960,
                                  otpNode: "ns1@mickey-mouse.disney.com",
                                  otpCookie: "SADFDFGDFG"},
                                 {hostname: "donald-duck.disney.com",
                                  os: 'Linux',
                                  uptime: 86420,
                                  version: 'only-web.rb',
                                  status: "healthy",
                                  clusterMembership: "inactiveFailed",
                                  ports: {proxy: 11211,
                                          direct: 11311},
                                  memoryTotal: 2032574464,
                                  memoryFree: 89864960,
                                  mcdMemoryAllocated: 64,
                                  mcdMemoryReserved: 256,
                                  otpNode: "ns1@donald-duck.disney.com",
                                  otpCookie: "SADFDFGDFG"},
                                 {hostname: "scrooge-mcduck.disney.com",
                                  uptime: 865000,
                                  version: "only-web.rb-2",
                                  status: "healthy",
                                  clusterMembership: "active",
                                  ports: {proxy: 11211,
                                          direct: 11311},
                                  memoryTotal: 2032574464,
                                  memoryFree: 89864960,
                                  mcdMemoryAllocated: 64,
                                  mcdMemoryReserved: 256,
                                  otpNode: "ns1@scrooge-mcduck.disney.com",
                                  otpCookie: "SADFDFGDFG"},
                                 {hostname: "goofy.disney.com",
                                  uptime: 86430,
                                  os: 'Linux',
                                  version: 'only-web.rb',
                                  status: "unhealthy",
                                  clusterMembership: "active",
                                  failedOver: false,
                                  memoryTotal: 2032574464,
                                  memoryFree: 889864960,
                                  mcdMemoryAllocated: 64,
                                  mcdMemoryReserved: 256,
                                  ports: {proxy: 11211,
                                          direct: 11311},
                                  otpNode: "ns1@goofy.disney.com",
                                  otpCookie: "SADFDFGDFG"}],
                         "storageTotals": {
                           "ram": {
                             "total": 2032558080,
                             "quotaTotal": 2032558080,
                             "used": 1641816064,
                             "quotaUsed": 1641816064
                           },
                           "hdd": {
                             "total": 239315349504.0,
                             "quotaTotal": 239315349504.0,
                             "used": 229742735523.0,
                             "quotaUsed": 229742735523.0
                           }
                         },
                         buckets: {
                           // GET returns first page of bucket details with link to next page
                           uri: "/pools/default/buckets"
                         },
                         controllers: {
                           addNode: {uri: '/controller/addNode'},
                           rebalance: {uri: '/controller/rebalance'},
                           failOver: {uri: '/controller/failOver'},
                           reAddNode: {uri: '/controller/reAddNode'},
                           testWorkload: {uri: '/pools/default/controller/testWorkload'},
                           ejectNode: {uri: "/controller/ejectNode"}
                         },
                         etag: "asdas123",
                         balanced: true,
                         rebalanceStatus: 'none',
                         rebalanceProgressUri: '/pools/default/rebalanceProgress',
                         stopRebalanceUri: '/controller/stopRebalance',
                         stats: {uri: "/pools/default/buckets/4/stats"}, // really for pool
                         name: "Default Pool"}],
      [get("pools", "default", "buckets"), [{name: "default",
                                             uri: "/pools/default/buckets/4",
                                             flushCacheUri: "/pools/default/buckets/4/controller/doFlush",
                                             stats: {uri: "/pools/default/buckets/4/stats"},
                                             quota: {
                                               ram: 12322423,
                                               hdd: 12322423
                                             },
                                             replicaNumber: 1,
                                             "basicStats": {
                                               "opsPerSec": 12,
                                               "diskFetches": 1,
                                               "quotaPercentUsed": 0.0,
                                               "diskUsed": 25935,
                                               "memUsed": 1232423,
                                               "itemCount": 1234
                                             }},
                                            {name: "Excerciser Application",
                                             uri: "/pools/default/buckets/5",
                                             testAppBucket: true,
                                             status: false,
                                             flushCacheUri: "/pools/default/buckets/5/controller/doFlush",
                                             stats: {uri: "/pools/default/buckets/5/stats"},
                                             quota: {
                                               ram: 123224230,
                                               hdd: 12322423000
                                             },
                                             replicaNumber: 1,
                                             "basicStats": {
                                               "opsPerSec": 13,
                                               "diskFetches": 1,
                                               "quotaPercentUsed": 0.0,
                                               "diskUsed": 259235,
                                               "memUsed": 12322423,
                                               "itemCount": 12324
                                             }},
                                            {name: "new-year-site",
                                             uri: "/pools/default/buckets/6",
                                             flushCacheUri: "/pools/default/buckets/6/controller/doFlush",
                                             stats: {uri: "/pools/default/buckets/6/stats"},
                                             quota: {
                                               ram: 12322423,
                                               hdd: 12322423
                                             },
                                             replicaNumber: 1,
                                             "basicStats": {
                                               "opsPerSec": 13,
                                               "diskFetches": 1.2,
                                               "quotaPercentUsed": 0.0,
                                               "diskUsed": 259353,
                                               "memUsed": 12324223,
                                               "itemCount": 12324
                                             }},
                                            {name: "new-year-site-staging",
                                             uri: "/pools/default/buckets/7",
                                             flushCacheUri: "/pools/default/buckets/7/controller/doFlush",
                                             stats: {uri: "/pools/default/buckets/7/stats"},
                                             quota: {
                                               ram: 12322423,
                                               hdd: 12322423
                                             },
                                             replicaNumber: 1,
                                             "basicStats": {
                                               "opsPerSec": 12,
                                               "diskFetches": 1,
                                               "quotaPercentUsed": 0.0,
                                               "diskUsed": 25935,
                                               "memUsed": 1232423,
                                               "itemCount": 1234
                                             }}]],
      [get("pools", "default", "buckets", x), function (x) {
        var allBuckets = MockedRequest.prototype.findResponseFor("GET", ["pools", "default", "buckets"]);
        x = parseInt(x, 10);
        var rv = _.clone(allBuckets[x % allBuckets.length]);
        rv.nodes = [];  // not used for now
        return rv;
      }],
      [get("pools", "default", "buckets", x, "stats"), method('handleStats')],
      [post("pools", "default", "buckets"), method('handleBucketsPost')],
      [post("pools", "default", "buckets", x), method('doNothingPOST')], //unused
      [post("pools", "default", "buckets", x, "controller", "doFlush"), method('doNothingPOST')], //unused
      [del("pools", "default", "buckets", x), method('handleBucketRemoval')],

      [get("nodes", x), {
        "license":"","licenseValue":false,"licenseValidUntil":"invalid",
        "memoryQuota":"",
        "storage":{"ssd":[],
                   "hdd":[{"path":"/srv/test",
                           "quotaMb":"none",
                           "state":"ok",
                           "usedByData": 25935,
                           "diskStats": {
                             "sizeKBytes": 233706396,
                             "usagePercent": 96}}]},
        "storageTotals": {
          "ram": {
            "total": 2032558080,
            "used": 1689321472
          },
          "hdd": {
            "total": 239315349504.0,
            "used": 229742735523.0
          }
        },
        availableStorage: {
          hdd: [{
            path: "/",
            sizeKBytes: 20000,
            usagePercent: 80
          }, {
            path: "/srv",
            sizeKBytes: 20000000,
            usagePercent: 10
          }, {
            path: "/usr",
            sizeKBytes: 2000000,
            usagePercent: 60
          }, {
            path: "/usr/local",
            sizeKBytes: 30000000,
            usagePercent: 0
          }, {
            path: "/home",
            sizeKBytes: 40000000,
            usagePercent: 90
          }
        ]},
        "hostname":"127.0.0.1",
        "version":"1.0.3_98_g5d1f7a2",
        "os":"i386-apple-darwin10.3.0",
        uptime: 86400,
        memoryTotal: 2032574464,
        memoryFree: 1589864960,
        mcdMemoryReserved: 2032574464,
        mcdMemoryAllocated: 89864960,
        "ports":{"proxy":11211,"direct":11210}}],
      [post("nodes", x, "controller", "settings"), expectParams(function ($data) {
        if ($data.memoryQuota && $data.memoryQuota != 'unlimited' && !(/^[0-9]+$/.exec($data.memoryQuota))) {
          this.errorResponse(["invalid memory quota", "second message"]);
        }
      }, opt("memoryQuota"), opt("license"))], //missing

      [post("node", "controller", "initStatus"), function ($data) {
        this.globalData.initValue = $data.initValue;
      }],

      [post("node", "controller", "doJoinCluster"), expectParams(method('handleJoinCluster'),
                                                                 "clusterMemberHostIp", "clusterMemberPort",
                                                                 "user", "password")],
      [post("pools", "default", "controller", "testWorkload"), method('handleWorkloadControlPost')],
      [post("controller", "ejectNode"), expectParams(method('doNothingPOST'),
                                                     "otpNode")],

      // params are otpNodes of nodes to be kept/ejected
      [post("controller", "rebalance"), expectParams(function () {
        if (__hookParams['rebalanceMismatch']) {
          return this.errorResponse({mismatch: 1});
        }

        var percent = 0;

        MockedRequest.globalData.rebalanceProgress = function () {
          return percent;
        }

        var intervalID = setInterval(function () {
          percent += 0.001;
        }, 50);

        MockedRequest.globalData.setRebalanceStatus('running');
        _.delay(function () {
          console.log("rebalance delay hit!");

          MockedRequest.globalData.rebalanceProgress = null;
          clearInterval(intervalID);

          MockedRequest.globalData.setRebalanceStatus('none');
        }, 8000);
      }, "knownNodes", "ejectedNodes")],
      [get("pools", "default", "rebalanceProgress"), function () {
        var pools = this.findResponseFor("GET", ["pools", "default"]);
        if (pools.rebalanceStatus == 'none') {
          return {status: 'none'};
        }
        var nodes = _.pluck(pools.nodes, 'otpNode');
        var rv = {
          status: pools.rebalanceStatus
        };
        var percent = 0.5;
        if (MockedRequest.globalData.rebalanceProgress) {
          percent = MockedRequest.globalData.rebalanceProgress();
        }
        _.each(nodes, function (name) {
          rv[name] = {progress: percent};
        });
        return rv;
      }],
      [post("controller", "stopRebalance"), method("doNothingPOST")],

      [post("controller", "addNode"), expectParams(method("doNothingPOST"),
                                                   "hostname",
                                                   "user", "password")],
      [post("controller", "failOver"), expectParams(method("doNothingPOST"),
                                                    "otpNode")],
      [post("controller", "reAddNode"), expectParams(method("doNothingPOST"),
                                                     "otpNode")],

      [post("settings", "web"), expectParams(method("doNothingPOST"),
                                             "port", "username", "password",
                                             opt("initStatus"))]
    ];

    rv.x = x;
    return rv;
  },
  doNothingPOST: function () {
  }
});

MockedRequest.prototype.globalData = MockedRequest.globalData = {
  initValue: "",
  findResponseFor: function (method, path) {
    return MockedRequest.prototype.findResponseFor(method, path);
  },
  setRebalanceStatus: function (status) {
    var pools = this.findResponseFor("GET", ["pools", "default"]);
    pools.rebalanceStatus = status;
  }
};


;(function () {
  MockedRequest.prototype.routes = MockedRequest.prototype.__defineRouting();
})();

TestingSupervisor.interceptAjax();

var __hookParams = {};

(function () {
  var href = window.location.href;
  var match = /\?(.*?)(?:$|#)/.exec(href);
  if (!match)
    return;
  var params = __hookParams = deserializeQueryString(match[1]);

  console.log("params", params);

  if (params['auth'] == '1')
    MockedRequest.prototype.checkAuth = MockedRequest.prototype.checkAuthReal;

  if (params['ajaxDelay']) {
    ajaxRespondDelay = parseInt(params['ajaxDelay'], 10);
  }

  if (params['nowiz']) {
    params['initValue'] = 'done';
  }

  if (params['initValue']) {
    MockedRequest.globalData.initValue = params['initValue'];
  }

  if (params['single']) {
    var pools = MockedRequest.prototype.findResponseFor("GET", ["pools", "default"]);
    pools.nodes = pools.nodes.slice(-1);
  }

  if (params['no-mcduck']) {
    var pools = MockedRequest.prototype.findResponseFor("GET", ["pools", "default"]);
    pools.nodes = _.reject(pools.nodes, function (n) {return n.hostname == "scrooge-mcduck.disney.com"});
  }

  if (params['rebalanceStatus']) {
    MockedRequest.globalData.setRebalanceStatus(params['rebalanceStatus']);
  }

  if (params['dialog']) {
    $(function () {
      $($i(params['dialog'])).show();
    });
  }
})();

//window.onerror = originalOnError;
