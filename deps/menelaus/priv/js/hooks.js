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
  initValue: "",
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
  },
  fakeResponse: function (data) {
    var self = this;
    if (data instanceof Function) {
      data.call(null, fakeResponse);
      return;
    }
    if (self.options.success)
      self.options.success(data, 'success');
  },
  authError: (function () {
    try {
      throw new Error("autherror")
    } catch (e) {
      return e;
    }
  })(),
  respond: function () {
    if (this.options.async != false)
      setTimeout($m(this, 'respondForReal'), window.ajaxRespondDelay);
    else
      this.respondForReal();
  },
  respondForReal: function () {
    if ($.ajaxSettings.beforeSend)
      $.ajaxSettings.beforeSend(this.fakeXHR);
    try {
      this.checkAuth();
      if (this.options.type == 'GET')
        return this.respondGET();
      return this.respondPOST();
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
  },
  checkAuth: function () {
  },
  checkAuthReal: function () {
    if (this.fakeXHR.login != 'admin' || this.fakeXHR.password != 'admin')
      throw this.authError;
  },
  respondGET: function () {
    var path = this.path;

    var resp;
    if (_.isEqual(path, ["logs"])) {
      resp = {
        "list": [
          {
            "type": "info",
            "code": 1,
            "module": "ns_config_log",
            "tstamp": 1265358398000,
            "shortText": "message",
            "text": "config changed"
          },
          {
            "type": "info",
            "code": 1,
            "module": "ns_node_disco",
            "tstamp": 1265358398000,
            "shortText": "message",
            "text": "otp cookie generated: bloeahcdnsddpotx"
          },
          {
            "type": "info",
            "code": 1,
            "module": "ns_config_log",
            "tstamp": 1265358398000,
            "shortText": "message",
            "text": "config changed"
          },
          {
            "type": "info",
            "code": 1,
            "module": "ns_config_log",
            "tstamp": 1265358399000,
            "shortText": "message",
            "text": "config changed"
          }
        ]
      }
    } else if (_.isEqual(path, ["settings", "web"])) {
      resp = {port:8080,username:"admin",password:""};
    } else if (_.isEqual(path, ["settings", "advanced"])) {
      resp = {alerts: {email:"alk@tut.by",
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
              ports:{proxyPort:11213,directPort:11212}};
      // var postData = {proxyPort:11213,
      //                 directPort:11212,
      //                 email: "",
      //                 email_alerts: "0", //sendAlerts
      //                 email_server_user: "",
      //                 email_server_pass: "",
      //                 email_server_addr: "",
      //                 email_server_port: "",
      //                 email_server_encrypt: "",
      //                 alert_server_down: "1" ...
      //                }
    } else if (path[0] == "pools") {
      if (path.length == 1) {
        // /pools
        resp = {
          implementationVersion: 'only-web.rb-unknown',
          componentsVersion: {
            "ns_server": "asdasd"
          },
          initStatus: this.initValue,
          pools: [
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
    } else if (_.isEqual(path, ["node"])) {
      resp = {"license":"HDJ1-HQR1-23J4-3847","licenseValidUntil":"2010/9/15"}
    } else {
      throw new Error("Unknown ajax path: " + this.options.url);
    }

    console.log("res is", resp);
    this.fakeResponse(resp);
  },
  respondPOST: function () {
    if (_.isEqual(this.path, ["node", "controller", "initStatus"])) {
      var data = this.deserialize(this.options.data);
      this.initValue = data['value'];
      return;
    }
    if (_.isEqual(this.path, ["buckets"])) {
      return this.handleBucketsPost();
    }
    if (_.isEqual(this.path, ["node", "controller", "doJoinCluster"])) {
      return this.handleJoinCluster();
    }
    if (_.isEqual(this.path, ["controllers", "testWorkload"])) {
      return this.handleWorkloadControlPost();
    }

    if (_.isEqual(this.path, ["settings", "web"])) {
      return this.fakeResponse({newBaseUri: 'http://' + document.location.host + '/'});
    }

    if (this.path[0] == "buckets" && this.options.type == 'DELETE')
      return this.handleBucketRemoval();

    this.fakeResponse('');
  },

  deserialize: deserializeQueryString,

  errorResponse: function (resp) {
    var self = this;
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

    var params = this.deserialize(this.options.data)
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
    var params = this.deserialize(this.options.data)
    console.log("params: ", params);
    var ok = true;

    _.each(('clusterMemberHostIp clusterMemberPort user password').split(' '), function (name) {
      if (!params[name] || !params[name].length) {
        ok = false;
      }
    });

    if (ok)
      this.fakeResponse('');
    else
      this.errorResponse([]);
  },

  handlePoolDetails: function () {
    var rv = {nodes: [{hostname: "mickey-mouse.disney.com",
                       status: "healthy",
                       ports: {proxy: 11211,
                               direct: 11311},
                       memoryTotal: 2032574464,
                       memoryFree: 1589864960,
                       mcMemoryTotal: 2032574464,
                       mcMemoryAllocated: 89864960,
                       otpNode: "ns1@mickey-mouse.disney.com",
                       otpCookie: "SADFDFGDFG"},
                      {hostname: "donald-duck.disney.com",
                       status: "healthy",
                       ports: {proxy: 11211,
                               direct: 11311},
                       memoryTotal: 2032574464,
                       memoryFree: 89864960,
                       mcdMemoryAllocated: 64,
                       mcdMemoryReserved: 256,
                       otpNode: "ns1@donald-duck.disney.com",
                       otpCookie: "SADFDFGDFG"},
                      {hostname: "goofy.disney.com",
                       status: "healthy",
                       memoryTotal: 2032574464,
                       memoryFree: 889864960,
                       mcdMemoryAllocated: 64,
                       mcdMemoryReserved: 256,
                       ports: {proxy: 11211,
                               direct: 11311},
                       otpNode: "ns1@goofy.disney.com",
                       otpCookie: "SADFDFGDFG"}],
              buckets: {
                // GET returns first page of bucket details with link to next page
                uri: "/buckets",
                // returns just names and uris, but complete (i.e. without pagination)
                shallowList: "/buckets?shallow=true"
              },
              controllers: {
                testWorkload: {uri: '/controllers/testWorkload'},
                ejectNode: {uri: "/controllers/ejectNode"}
              },
              stats: {uri: "/buckets/4/stats?really_for_pool=1"},
              name: "Default Pool"}
    if (!__hookParams['multinode']) {
      rv.nodes = rv.nodes.slice(-1);
    }
    return rv;
  },
  bucketsList: [{name: "default",
                 uri: "/buckets/4",
                 flushCacheUri: "/buckets/4/flush",
                 stats: {uri: "/buckets/4/stats"},
                 basicStats: {
                   cacheSize: 64, // in megs
                   opsPerSec: 100,
                   evictionsPerSec: 5,
                   cachePercentUsed: 50
                 }},
                {name: "Excerciser Application",
                 uri: "/buckets/5",
                 testAppBucket: true,
                 status: false,
                 controlURL: "/testappuri",
                 flushCacheUri: "/buckets/5/flush",
                 stats: {uri: "/buckets/5/stats"},
                 basicStats: {
                   cacheSize: 65, // in megs
                   opsPerSec: 101,
                   evictionsPerSec: 6,
                   cachePercentUsed: 51
                 }},
                {name: "new-year-site",
                 uri: "/buckets/6",
                 flushCacheUri: "/buckets/6/flush",
                 stats: {uri: "/buckets/6/stats"},
                 basicStats: {
                   cacheSize: 66, // in megs
                   opsPerSec: 102,
                   evictionsPerSec: 7,
                   cachePercentUsed: 52
                 }},
                {name: "new-year-site-staging",
                 uri: "/buckets/7",
                 flushCacheUri: "/buckets/7/flush",
                 stats: {uri: "/buckets/7/stats"},
                 basicStats: {
                   cacheSize: 67, // in megs
                   opsPerSec: 103,
                   evictionsPerSec: 8,
                   cachePercentUsed: 53
                 }}],
  handleWorkloadControlPost: function () {
    var params = this.deserialize(this.options.data)
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
  handleBucketList: function () {
    return _.clone(this.bucketsList);
  },
  handleStats: function () {
    var params = this.options['data'];
    var opsPerSecondZoom = params['opsPerSecondZoom'] || "now";
    var samplesSelection = [[3,14,23,52,45,25,23,22,50,67,59,55,54,41,36,35,26,61,72,49,60],
                            [23,14,45,64,41,45,43,25,14,11,18,36,64,76,86,86,79,78,55,59,49],
                            [42,65,42,63,81,87,74,84,56,44,71,64,49,48,55,46,37,46,64,33,18],
                            [61,65,64,75,77,57,68,76,64,61,66,63,68,37,32,60,72,54,43,41,55]];
    var samples = {};
    for (var idx in StatGraphs.recognizedStats) {
      var data = samplesSelection[idx%4];
      samples[StatGraphs.recognizedStats[idx]] = _.map(data, function (i) {return i*10E9});
    }
    var samplesSize = samplesSelection[0].length;

    var samplesInterval = 1000;

    var now = (new Date()).valueOf();
    var lastSampleTstamp = now;

    if (samplesInterval == 1000) {
      var rotates = ((now / 1000) >> 0) % samplesSize;
      var newSamples = {};
      for (var k in samples) {
        var data = samples[k];
        newSamples[k] = data.concat(data).slice(rotates, rotates + samplesSize);
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

  if (params['initValue']) {
    MockedRequest.prototype.initValue = params['initValue'];
  }
})();
