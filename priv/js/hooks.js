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
    var cell = CurrentStatTargetHandler.currentStatTargetCell;
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
  interceptedAjax: function (original, options) {
    if (options.type != 'GET')
      return; // original(options);
    console.log("intercepted ajax:", options);
    var url = options.url;
    var hostPrefix = document.location.protocol + ":/" + document.location.host;
    if (url.indexOf(hostPrefix) == 0)
      url = url.substring(hostPrefix);
    if (url.indexOf("/") == 0)
      url = url.substring(1);
    if (url.lastIndexOf("/") == url.length - 1)
      url = url.substring(0, url.length - 1);

    var path = url.split("/")

    var fakeResponse = function (data) {
      _.defer(function () {
        if (data instanceof Function) {
          data.call(null, fakeResponse);
          return;
        }
        options.success.call(null, data);
      });
    }

    var resp;
    if (path[0] == "pools") {
      if (path.length == 1) {
        // /pools
        resp = {pools: [
          {name: 'default',
           uri: "/pools/default"},
          {name: 'Another Pool',
           uri: '/pools/Another Pool'}]};
      } else {
        // /pools/:id
        if (path[1] == 'default') {
          resp = {nodes: [{ipAddress: "10.0.1.20",
                           status: "healthy",
                           ports: {routing: 11211,
                                   caching: 11311,
                                   kvstore: 11411},
                           name: "first_node",
                           fqdn: "first_node.in.pool.com"},
                          {ipAddress: "10.0.1.21",
                           status: "healthy",
                           ports: {routing: 11211,
                                   caching: 11311,
                                   kvstore: 11411},
                           uri: "/addresses/10.0.1.20",
                           name: "second_node",
                           fqdn: "second_node.in.pool.com"}],
                  buckets: [{uri: "/buckets/4",
                             name: "Excerciser Application"}],
                  stats: {uri: "/buckets/4/stats?really_for_pool=1"},
                  name: "Default Pool"};
        } else {
          resp = {nodes: [{ipAddress: "10.0.1.20",
                           status: "healthy",
                           ports: {routing: 11211,
                                   caching: 11311,
                                   kvstore: 11411},
                           name: "first_node",
                           fqdn: "first_node.in.pool.com"},
                          {ipAddress: "10.0.1.21",
                           status: "healthy",
                           ports: {routing: 11211,
                                   caching: 11311,
                                   kvstore: 11411},
                           uri: "/addresses/10.0.1.20",
                           name: "second_node",
                           fqdn: "second_node.in.pool.com"}],
                  buckets: [{uri: "/buckets/5",
                             name: "Excerciser Another"}],
                  stats: {uri: "/buckets/4/stats?really_for_pool=1"},
                  name: "Another Pool"};
        }
      }
    } else if (path[0] == 'buckets') {
      if (path.length == 2) {
        // /buckets/:id
        if (path[1] == "4")
          resp = {pool_uri: "asdasd",
                  stats: {uri: "/buckets/4/stats"},
                  name: "Excerciser Application"};
        else
          resp = {pool_uri: "asdasd",
                  stats: {uri: "/buckets/5/stats"},
                  name: "Excerciser Another"};
      } else {
        // /buckets/:id/stats
        var params = options["data"];
        var opsPerSecondZoom = params['opspersecond_zoom'] || "1hr";
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

        var samplesInterval = 1;
        if (opsPerSecondZoom == "24hr")
          samplesInterval = 86400 / samplesSize;
        else if (opsPerSecondZoom == "1hr")
          samplesInterval = 3600 / samplesSize;

        var now = (new Date()).valueOf();
        var lastSampleTstamp = now;

        if (samplesInterval == 1) {
          var rotates = ((now / 1000) >> 0) % samplesSize;
          var newSamples = {};
          for (var k in samples) {
            var data = samples[k];
            newSamples[k] = data.concat(data).slice(rotates, rotates + samplesSize);
          }
          samples = newSamples;
        }

        var startTstampParam = params["opsbysecond_start_tstamp"];
        if (startTstampParam !== undefined) {
          var startTstamp = parseInt(startTstampParam, 10);
          
          var intervals = Math.floor((now - startTstampParam) / samplesInterval / 1000);
          if (intervals > samplesSize) {
            throw new Error("should not happen");
          }
          lastSampleTstamp = startTstamp + intervals * samplesInterval * 1000;

          var newSamples = {};
          for (var k in samples) {
            var data = samples[k];
            var newData = data.slice(-intervals);
            newSamples[k] = newData;
          }
          samples = newSamples;
        }

        var resp = {
          hot_keys: [{name: "user:image:value",
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
                        'samples_interval': samplesInterval},
                       samples)};
      }
    } else if (path[0] == 'alerts' && path.length == 1) {
      // /alerts
      resp = this.alertsResponse;
    } else {
      throw new Error("Unknown ajax path: " + options.url);
    }

    _.defer(function () {
      fakeResponse(resp);
    });
  }
};

TestingSupervisor.interceptAjax();
