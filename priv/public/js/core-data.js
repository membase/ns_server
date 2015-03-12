/**
   Copyright 2015 Couchbase, Inc.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
 **/
function addBasicAuth(xhr, login, password) {
  var auth = 'Basic ' + Base64.encode(login + ':' + password);
  xhr.setRequestHeader('Authorization', auth);
}

function onUnexpectedXHRError(xhr, xhrStatus, errMsg) {
  var status;
  var readyState;
  var self = this;

  window.onUnexpectedXHRError = function () {};

  if (Abortarium.isAborted(xhr)) {
    return;
  }

  // for manual interception
  if ('debuggerHook' in onUnexpectedXHRError) {
    onUnexpectedXHRError.debuggerHook(xhr, xhrStatus, errMsg);
  }

  try {
    status = xhr.status;
  } catch (e) {}

  try {
    readyState = xhr.readyState;
  } catch (e) {}

  if (status === 401) {
    return reloadApp();
  }

  if ('JSON' in window && 'sessionStorage' in window) {
    (function () {
      var json;
      var responseText;
      var s = {};
      var e;
      var er;

      try {
        responseText = String(xhr.responseText);
      } catch (e) {}

      try {
        _.each(self, function (value, key) {
          if (_.isString(key) || _.isNumber(key)) {
            s[key] = value;
          }
        });
        json = JSON.stringify(s);
      } catch (er) {
        json = "";
      }
      sessionStorage.reloadCause = "s: " + json +
        "\nxhrStatus: " + xhrStatus + ",\nxhrReadyState: " + readyState +
        ",\nerrMsg: " + errMsg + ",\nstatusCode: " + status +
        ",\nresponseText:\n" + responseText;
      sessionStorage.reloadTStamp = (new Date()).valueOf();
    }());
  }

  var reloadInfo = $.cookie('ri');
  var ts;

  var now = (new Date()).valueOf();
  if (reloadInfo) {
    ts = parseInt(reloadInfo, 10);
    if ((now - ts) < 15*1000) {
      $.cookie('rf', null); // clear reload-info cookie, so that
                            // manual reload don't cause 'console has
                            // been reloaded' flash message

      var details = DAL.cells.currentPoolDetailsCell.value;
      var notAlone = details && details.nodes.length > 1;
      var msg = 'The application received multiple invalid responses from the server.  The server log may have details on this error.  Reloading the application has been suppressed.';
      if (notAlone) {
        msg += '\n\nYou may be able to load the console from another server in the cluster.';
      }
      alert(msg);

      return;
    }
  }

  $.cookie('ri', String((new Date()).valueOf()), {expires:0});
  $.cookie('rf', '1');
  reloadAppWithDelay(500);
}

$.ajaxSetup({
  error: onUnexpectedXHRError,
  timeout: 30000,
  cache: false,
  beforeSend: function (xhr, options) {
    xhr.setRequestHeader('invalid-auth-response', 'on');
    xhr.setRequestHeader('Cache-Control', 'no-cache');
    xhr.setRequestHeader('Pragma', 'no-cache');
    xhr.setRequestHeader('ns_server-ui', 'yes');
  },
  dataFilter: function (data, type) {
    if (type === "json" && data == "") {
      throw new Error("empty json");
    }
    return data;
  }
});

var DAL = {
  ready: false,
  version: undefined,
  cells: {},
  onReady: function (thunk) {
    if (DAL.ready) {
      thunk.call(null);
    } else {
      $(window).one('dao:ready', function () {thunk();});
    }
  },
  appendedVersion: false,
  parseVersion: function (str) {
    // Expected string format:
    //   {release version}-{build #}-{Release type or SHA}-{enterprise / community}
    // Example: "1.8.0-9-ga083a1e-enterprise"
    var a = str.split(/[-_]/);
    a[0] = (a[0].match(/[0-9]+\.[0-9]+\.[0-9]+/) || ["0.0.0"])[0];
    a[1] = a[1] || "0";
    a[2] = a[2] || "unknown";
    // We append the build # to the release version when we display in the UI so that
    // customers think of the build # as a descriptive piece of the version they're
    // running (which in the case of maintenance packs and one-off's, it is.)
    a[0] = a[0] + "-" + a[1];
    a[3] = (a[3] && (a[3].substr(0, 1).toUpperCase() + a[3].substr(1))) || "DEV";
    return a; // Example result: ["1.8.0-9", "9", "ga083a1e", "Enterprise"]
  },
  prettyVersion: function(str, full) {
    var a = DAL.parseVersion(str);
    // Example default result: "1.8.0-7 Enterprise Edition (build-7)"
    // Example full result: "1.8.0-7 Enterprise Edition (build-7-g35c9cdd)"
    var suffix = "";
    if (full) {
      suffix = '-' + a[2];
    }
    return [a[0], a[3], "Edition", "(build-" + a[1] + suffix + ")"].join(' ');
  },
  loginSuccess: function (data) {
    var rows = data.pools;

    var implementationVersion = data.implementationVersion;

    (function () {
      var match = /(\?|&)forceVersion=([^&#]+)/.exec(document.location.href);
      if (!match) {
        return;
      }
      implementationVersion = decodeURIComponent(match[2]);
      console.log("forced version: ", implementationVersion);
    })();

    DAL.cells.isEnterpriseCell.setValue(!!data.isEnterprise);

    if (implementationVersion) {
      DAL.version = implementationVersion;
      DAL.componentsVersion = data.componentsVersion;
      DAL.uuid = data.uuid;
      var parsedVersion = DAL.parseVersion(implementationVersion);
      if (!DAL.appendedVersion) {
        document.title = document.title +
          " (" + parsedVersion[0] + ")";
        var v = DAL.prettyVersion(implementationVersion);
        $('.version > .couchbase-version').text(v).parent().show();
        DAL.appendedVersion = true;
      }
    }

    DAL.cells.isROAdminCell.setValue(data.isROAdminCreds);

    var provisioned = !!rows.length;
    var authenticated = data.isAdminCreds;
    if (provisioned && !authenticated) {
      return false;
    }

    DAL.login = true;

    DAL.ready = true;
    $(window).trigger('dao:ready');

    DAL.cells.poolList.setValue(rows);

    // If the cluster appears to be configured, then don't let user go
    // back through init dialog.
    SetupWizard.show(provisioned ? 'done' : '');

    return true;
  },
  switchSection: function (section) {
    DAL.switchedSection = section;
    if (DAL.sectionsEnabled) {
      DAL.cells.mode.setValue(section);
    }
  },
  enableSections: function () {
    DAL.sectionsEnabled = true;
    DAL.cells.mode.setValue(DAL.switchedSection);
  },
  tryNoAuthLogin: function () {
    var rv;
    var auth;
    var arr;

    function cb(data, status) {
      if (status === 'success') {
        rv = DAL.loginSuccess(data);
      }
    }

    $.ajax({
      type: 'GET',
      url: "/pools",
      dataType: 'json',
      async: false,
      success: cb,
      error: cb});

    return rv;
  },
  performLogin: function (login, password, callback) {
    $.ajax({
      type: 'POST',
      url: "/uilogin",
      data: $.param({user: login,
                     password: password}),
      success:loginCB,
      error:loginCB});

    return;

    function loginCB(data, status) {
      if (status != 'success') {
        return callback(status, data);
      }
      if (!DAL.tryNoAuthLogin()) {
        // this should be impossible
        reloadApp();
        return;
      }
      callback(status);
    }
  },
  initiateLogout: function (callback) {
    DAL.ready = false;
    DAL.cells.mode.setValue(undefined);
    DAL.cells.currentPoolDetailsCell.setValue(undefined);
    DAL.cells.poolList.setValue(undefined);
    $.ajax({
      type: 'POST',
      url: "/uilogout",
      success: callback,
      success: callback
    });
  }
};

(function () {
  this.mode = new Cell();
  this.poolList = new Cell();

  // this cell lowers comet/push timeout for overview sections _and_ makes
  // sure we don't fetch pool details if mode is not set (we're in
  // wizard)
  var poolDetailsPushTimeoutCell = new Cell(function (mode) {
    if (mode === 'overview' || mode === 'manage_servers') {
      return 3000;
    }
    return 20000;
  }, {
    mode: this.mode
  });

  this.currentPoolDetailsCell = Cell.needing(this.poolList,
                                             poolDetailsPushTimeoutCell)
    .computeEager(function (v, poolList, pushTimeout) {
      var url;

      if (!poolList[0]) {
        return;
      }

      url = poolList[0].uri;
      function poolDetailsValueTransformer(data) {
        // we clear pool's name to display empty name in analytics
        data.name = '';
        return data;
      }

      // NOTE: when this request gets 4xx it means cluster was
      // re-initialized or auth is expired, so we should reload app
      // into setup wizard or login form
      function missingValueProducer(xhr, options, errorMarker) {
        reloadApp();
        return errorMarker;
      }

      return future.getPush({url: url,
                             missingValueProducer: missingValueProducer},
                            poolDetailsValueTransformer,
                            this.self.value, pushTimeout);
    });
  this.currentPoolDetailsCell.equality = _.isEqual;
  this.currentPoolDetailsCell.name("currentPoolDetailsCell");

  this.nodeStatusesURICell = Cell.computeEager(function (v) {
    return v.need(DAL.cells.currentPoolDetailsCell).nodeStatusesUri;
  });

  this.nodeStatusesCell = Cell.compute(function (v) {
    return future.get({url: v.need(DAL.cells.nodeStatusesURICell)});
  });

}).call(DAL.cells);

(function (cells) {
  cells.isEnterpriseCell = new Cell();
  cells.isEnterpriseCell.isEqual = _.isEqual;
  cells.isEnterpriseCell.subscribeValue(function (isEnterprise) {
    if (isEnterprise) {
      $("body").addClass('dynamic_enterprise-mode').removeClass('dynamic_community-mode');
      $("#switch_support_forums").attr('href', 'http://support.couchbase.com');
    } else {
      $("body").addClass('dynamic_community-mode').removeClass('dynamic_enterprise-mode');
      $("#switch_support_forums").attr('href', 'http://www.couchbase.com/communities/');
    }
  });

  cells.isROAdminCell = new Cell();
  DAL.cells.isROAdminCell.subscribeValue(function (isROAdmin) {
    if (isROAdmin) {
      $("body").addClass('dynamic_roadmin-mode');
    } else {
      $("body").removeClass('dynamic_roadmin-mode');
    }
  });

  cells.serverGroupsUriRevisoryCell = Cell.compute(function (v) {
    return v.need(cells.currentPoolDetailsCell).serverGroupsUri || null;
  }).name("serverGroupsUriRevisoryCell");
  cells.serverGroupsUriRevisoryCell.equality = function (a, b) {return a === b};

  cells.groupsUpdatedByRevisionCell = Cell.compute(function (v) {
    var url = v.need(cells.serverGroupsUriRevisoryCell);
    if (url === null) {
      return {groups: []};
    }
    return future.get({url: url});
  }).name("groupsUpdatedByRevisionCell");

  cells.groupsAvailableCell = Cell.compute(function (v) {
    var url = v.need(cells.serverGroupsUriRevisoryCell);
    var isEnterprise = v.need(cells.isEnterpriseCell);
    return url !== null && isEnterprise;
  });

  cells.hostnameToGroupCell = Cell.compute(function (v) {
    var groups = v.need(cells.groupsUpdatedByRevisionCell).groups;
    var rv = {};
    _.each(groups, function (group) {
      _.each(group.nodes, function (node) {
        rv[node.hostname] = group;
      });
    });
    return rv;
  }).name("hostnameToGroupCell");

})(DAL.cells);

(function () {
  var pendingEject = []; // nodes to eject on next rebalance
  var pending = []; // nodes for pending tab
  var active = []; // nodes for active tab
  var allNodes = []; // all known nodes
  var cell;

  function formula(v) {
    var self = this;
    var pending = [];
    var active = [];
    allNodes = [];

    var isEnterprise = v.need(DAL.cells.isEnterpriseCell);
    var compatVersion = v(DAL.cells.compatVersion);
    var compat30 = encodeCompatVersion(3, 0);
    var poolDetails = v.need(DAL.cells.currentPoolDetailsCell);
    var hostnameToGroup = {};
    var detailsAreStale = v.need(IOCenter.staleness);

    if (v.need(DAL.cells.groupsAvailableCell)) {
      hostnameToGroup = v.need(DAL.cells.hostnameToGroupCell);
    }

    var nodes = _.map(poolDetails.nodes, function (n) {
      n = _.clone(n);
      var group = hostnameToGroup[n.hostname];
      if (group) {
        // it's possible hostnameToGroupCell is still in
        // the process of being invalidated. So group might
        // actually be not yet updated. That's fine. All
        // external observers will only see that cell after
        // it's fully "stable".
        //
        // If we're not rack-aware (due to compat or
        // non-enterprise-ness), we'll skip this path too
        n.group = group.name;
      }
      return n;
    });

    var nodeNames = _.pluck(nodes, 'hostname');
    _.each(nodes, function (n) {
      var mship = n.clusterMembership;
      if (mship === 'active') {
        active.push(n);
      } else {
        pending.push(n);
      }
      if (mship === 'inactiveFailed') {
        active.push(n);
      }
    });

    var stillActualEject = [];
    _.each(pendingEject, function (node) {
      var original = _.detect(nodes, function (n) {
        return n.otpNode == node.otpNode;
      });
      if (!original || original.clusterMembership === 'inactiveAdded') {
        return;
      }
      stillActualEject.push(original);
      original.pendingEject = true;
    });

    pendingEject = stillActualEject;

    pending = pending = pending.concat(pendingEject);

    function hostnameComparator(a, b) {
      // note: String() is in order to deal with possible undefined
      var rv = naturalSort(String(a.group), String(b.group));
      if (rv != 0) {
        return rv;
      }
      return naturalSort(a.hostname, b.hostname);
    }
    pending.sort(hostnameComparator);
    active.sort(hostnameComparator);

    allNodes = _.uniq(active.concat(pending));

    var reallyActive = _.select(active, function (n) {
      return n.clusterMembership === 'active' && !n.pendingEject;
    });

    if (reallyActive.length == 1) {
      reallyActive[0].lastActive = true;
    }

    _.each(allNodes, function (n) {
      var interestingStats = n.interestingStats;
      if (interestingStats &&
          ('couch_docs_data_size' in interestingStats) &&
          ('couch_views_data_size' in interestingStats) &&
          ('couch_docs_actual_disk_size' in interestingStats) &&
          ('couch_views_actual_disk_size' in interestingStats)) {
        n.couchDataSize = interestingStats.couch_docs_data_size + interestingStats.couch_views_data_size;
        n.couchDiskUsage = interestingStats.couch_docs_actual_disk_size + interestingStats.couch_views_actual_disk_size;
      }

      n.ejectPossible = !detailsAreStale && !n.pendingEject;
      n.failoverPossible = !detailsAreStale && (n.clusterMembership !== 'inactiveFailed');
      n.reAddPossible = !detailsAreStale && (n.clusterMembership === 'inactiveFailed' && n.status !== 'unhealthy');
      n.deltaRecoveryPossible = !detailsAreStale && compatVersion && (compatVersion >= compat30) && ($.inArray("kv", n.services) >= 0);

      var nodeClass = '';
      if (n.clusterMembership === 'inactiveFailed') {
        nodeClass = n.status === 'unhealthy' ? 'server_down failed_over' : 'failed_over';
      } else if (n.status === 'healthy') {
        nodeClass = 'server_up';
      } else if (n.status === 'unhealthy') {
        nodeClass = 'server_down';
      } else if (n.status === 'warmup') {
        nodeClass = 'server_warmup';
      }
      if (n.lastActive) {
        nodeClass += ' last-active';
      }
      n.nodeClass = nodeClass;
    });

    return {
      stale: detailsAreStale,
      pendingEject: pendingEject,
      pending: pending,
      active: active,
      allNodes: allNodes
    };
  }

  cell = DAL.cells.serversCell = Cell.compute(formula);
  cell.cancelPendingEject = function (node) {
    node.pendingEject = false;
    pendingEject = _.without(pendingEject, node);
    cell.invalidate();
  };
  DAL.cells.mayRebalanceWithoutSampleLoadingCell = Cell.computeEager(function (v) {
    var details = v.need(DAL.cells.currentPoolDetailsCell);
    var isRebalancing = details && details.rebalanceStatus !== 'none';
    var isBalanced = details && details.balanced;

    var isInRecoveryMode = v.need(DAL.cells.inRecoveryModeCell);

    var servers = v.need(DAL.cells.serversCell);
    var isPedingServersAvailable = !!servers.pending.length;
    var unhealthyActive = _.detect(servers.active, function (n) {
      return n.clusterMembership == 'active'
      && !n.pendingEject
      && n.status === 'unhealthy'
    });

    return !isRebalancing && !isInRecoveryMode && (isPedingServersAvailable || !isBalanced) && !unhealthyActive;
  }).name('mayRebalanceWithoutSampleLoadingCell');
}());

// detailedBuckets
(function (cells) {
  var currentPoolDetailsCell = cells.currentPoolDetailsCell;

  // we're using separate 'intermediate' cell to isolate all updates
  // of currentPoolDetailsCell from updates of buckets uri (which
  // basically never happens)
  var bucketsURI = DAL.cells.bucketsURI = Cell.compute(function (v) {
    return v.need(currentPoolDetailsCell).buckets.uri;
  });

  var rawDetailedBuckets = Cell.compute(function (v) {
    return future.get({url: v.need(bucketsURI) + "&basic_stats=true"});
  });
  rawDetailedBuckets.keepValueDuringAsync = true;

  cells.bucketsListCell = Cell.compute(function (v) {
    var values = _.clone(v.need(rawDetailedBuckets));
    // adding a child object for storing bucket by their type
    values.byType = {"membase":[], "memcached":[]};

    _.each(values, function (bucket) {
      var storageTotals = bucket.basicStats.storageTotals;

      if (bucket.bucketType == 'memcached') {
        bucket.bucketTypeName = 'Memcached';
      } else if (bucket.bucketType == 'membase') {
        bucket.bucketTypeName = 'Couchbase';
      } else {
        bucket.bucketTypeName = bucket.bucketType;
      }
      if (values.byType[bucket.bucketType] === undefined) {
        values.byType[bucket.bucketType] = [];
      }
      values.byType[bucket.bucketType].push(bucket);

      bucket.ramQuota = bucket.quota.ram;
      bucket.totalRAMSize = storageTotals.ram.total;
      bucket.totalRAMUsed = bucket.basicStats.memUsed;
      bucket.otherRAMSize = storageTotals.ram.used - bucket.totalRAMUsed;
      bucket.totalRAMFree = storageTotals.ram.total - storageTotals.ram.used;

      bucket.RAMUsedPercent = calculatePercent(bucket.totalRAMUsed, bucket.totalRAMSize);
      bucket.RAMOtherPercent = calculatePercent(bucket.totalRAMUsed + bucket.otherRAMSize, bucket.totalRAMSize);

      bucket.totalDiskSize = storageTotals.hdd.total;
      bucket.totalDiskUsed = bucket.basicStats.diskUsed;
      bucket.otherDiskSize = storageTotals.hdd.used - bucket.totalDiskUsed;
      bucket.totalDiskFree = storageTotals.hdd.total - storageTotals.hdd.used;

      bucket.diskUsedPercent = calculatePercent(bucket.totalDiskUsed, bucket.totalDiskSize);
      bucket.diskOtherPercent = calculatePercent(bucket.otherDiskSize + bucket.totalDiskUsed, bucket.totalDiskSize);
      var h = _.reduce(_.pluck(bucket.nodes, 'status'),
                       function(counts, stat) {
                         counts[stat] = (counts[stat] || 0) + 1;
                         return counts;
                       },
                       {});
      // order of these values is important to match pie chart colors
      bucket.healthStats = [h.healthy || 0, h.warmup || 0, h.unhealthy || 0];
    });

    return values;
  });
  cells.bucketsListCell.equality = _.isEqual;
  cells.bucketsListCell.delegateInvalidationMethods(rawDetailedBuckets);

  cells.isBucketsAvailableCell = Cell.compute(function (v) {
    return !!v.need(DAL.cells.bucketsListCell).length;
  }).name("isBucketsAvailableCell");

  cells.bucketsListCell.refresh = function (callback) {
    rawDetailedBuckets.invalidate(callback);
  };
})(DAL.cells);

(function () {
  var thisNodeCell = Cell.computeEager(function (v) {
    var details = v(DAL.cells.currentPoolDetailsCell);
    if (!details) {
      // if we already have value, but pool details are undefined
      // (likely reloading), keep old value to avoid interfering with
      // in-flight CAPI requests
      return this.self.value;
    }

    var nodes = details.nodes;
    var thisNode = _.detect(nodes, function (n) {return n.thisNode;});
    if (!thisNode) {
      return this.self.value;
    }

    return thisNode;
  });

  var capiBaseCell = DAL.cells.capiBase = Cell.computeEager(function (v) {
    var thisNode = v(thisNodeCell);
    if (!thisNode) {
      return this.self.value;
    }

    return window.location.protocol === "https:" ? thisNode.couchApiBaseHTTPS : thisNode.couchApiBase;
  }).name("capiBaseCell");

  var compatVersionCell = DAL.cells.compatVersion = Cell.computeEager(function (v) {
    var thisNode = v(thisNodeCell);
    if (!thisNode) {
      return this.self.value;
    }

    return thisNode.clusterCompatibility;
  }).name("compatVersion");

  DAL.cells.runningInCompatMode = Cell.computeEager(function (v) {
    var compatVersion = v(compatVersionCell);
    if (!compatVersion) {
      // when our dependent cells is unknown we keep our old value
      return this.self.value;
    }

    return compatVersion == encodeCompatVersion(1, 8);
  });

  $.ajaxPrefilter(function (options, originalOptions, jqXHR) {
    var capiBase = capiBaseCell.value;
    if (!capiBase) {
      return;
    }
    var capiBaseLen = capiBase.length;

    if (options.crossDomain && options.url.substring(0, capiBaseLen) === capiBase) {
      options.crossDomain = false;
      options.url = "/couchBase/" + options.url.slice(capiBaseLen);
    }
  });

  DAL.subscribeWhenSection = function (cell, section, body) {
    var intermediary = Cell.compute(function (v) {
      if (v.need(DAL.cells.mode) !== section)
        return;
      return v(cell);
    });
    return intermediary.subscribeValue(body);
  };
})();

(function () {
  var tasksProgressURI = DAL.cells.tasksProgressURI = Cell.compute(function (v) {
    return v.need(DAL.cells.currentPoolDetailsCell).tasks.uri;
  }).name("tasksProgressURI");
  var tasksProgressCell = DAL.cells.tasksProgressCell = Cell.computeEager(function (v) {
    var uri = v.need(tasksProgressURI);
    return future.get({url: uri});
  }).name("tasksProgressCell");
  tasksProgressCell.keepValueDuringAsync = true;
  var tasksRefreshPeriod = DAL.cells.tasksRefreshPeriod = Cell.compute(function (v) {
    var tasks = v.need(tasksProgressCell);
    var minPeriod = 1 << 28;
    _.each(tasks, function (taskInfo) {
      var period = taskInfo.recommendedRefreshPeriod;
      if (!period) {
        return;
      }
      period = (period * 1000) >> 0;
      if (period < minPeriod) {
        minPeriod = period;
      }
    });
    return minPeriod;
  }).name("tasksRefreshPeriod");
  Cell.subscribeMultipleValues(function (period) {
    if (!period) {
      return;
    }
    tasksProgressCell.recalculateAfterDelay(period);
  }, tasksRefreshPeriod, tasksProgressCell);

  var tasksRecoveryCell = DAL.cells.tasksRecoveryCell =
        Cell.computeEager(function (v) {
          var tasks = v.need(tasksProgressCell);
          return _.detect(tasks, function (taskInfo) {
            return taskInfo.type === "recovery";
          }) || null;
        }).name("tasksRecoveryCell");

  var tasksRebalanceCell = DAL.cells.tasksRebalanceCell =
        Cell.computeEager(function (v) {
          var tasks = v.need(tasksProgressCell);
          return _.detect(tasks,
                          function (taskInfo) {
                            return taskInfo.type === "rebalance" &&
                              taskInfo.status === "running";
                          });
        }).name("tasksRebalanceCell");

  var inRebalanceCell = DAL.cells.inRebalanceCell =
        Cell.computeEager(function (v) {
          return !!v.need(tasksRebalanceCell);
        }).name("inRebalanceCell");

  var inRecoveryModeCell = DAL.cells.inRecoveryModeCell =
        Cell.computeEager(function (v) {
          return !!v.need(tasksRecoveryCell);
        }).name("inRecoveryModeCell");

  var isLoadingSamplesCell = DAL.cells.isLoadingSamplesCell =
        Cell.computeEager(function (v) {
          var tasks = v.need(tasksProgressCell);
          return !!_.detect(tasks, function (taskInfo) {
            return taskInfo.type === "loadingSampleBucket" && taskInfo.status === "running";
          });
        }).name("isLoadingSamplesCell");
})();

var RecentlyCompacted = mkClass.turnIntoLazySingleton(mkClass({
  initialize: function () {
    setInterval(_.bind(this.onInterval, this), 2000);
    this.triggeredCompactions = {};
    this.startedCompactionsCell = (new Cell()).name("startedCompactionsCell");
    this.updateCell();
  },
  updateCell: function () {
    var obj = {};
    _.each(this.triggeredCompactions, function (v, k) {
      obj[k] = true;
    });
    this.startedCompactionsCell.setValue(obj);
  },
  registerAsTriggered: function (url, undoBody) {
    if (this.triggeredCompactions[url]) {
      this.gcThings();
      if (this.triggeredCompactions[url]) {
        return;
      }
    }
    var desc = {url: url,
                undoBody: undoBody || Function(),
                gcAt: (new Date()).valueOf() + 10000};
    this.triggeredCompactions[url] = desc;
    this.updateCell();
  },
  canCompact: function (url) {
    var desc = this.triggeredCompactions[url];
    if (!desc) {
      return true;
    }
    return desc.gcAt <= (new Date()).valueOf();
  },
  gcThings: function () {
    var now = new Date();
    var expired = [];
    var notExpired = {};
    _.each(this.triggeredCompactions, function (desc) {
      if (desc.gcAt > now) {
        notExpired[desc.url] = desc;
      } else {
        expired.push(desc);
      }
    });
    this.triggeredCompactions = notExpired;
    _.each(expired, function (desc) {
      var undo = desc.undoBody;
      if (undo) {
        undo();
      }
    });
    this.updateCell();
  },
  onInterval: function () {
    this.gcThings();
  }
}));

function formatWarmupMessages(warmupTasks, keyComparator, keyName) {
  warmupTasks = _.clone(warmupTasks);
  warmupTasks.sort(keyComparator);
  var originLength = warmupTasks.length;
  if (warmupTasks.length > 3) {
    warmupTasks.length = 3;
  }

  var rv = _.map(warmupTasks, function (task) {
    var message = task.stats.ep_warmup_state;

    switch (message) {
      case "loading keys":
        message += " (" + task.stats.ep_warmup_key_count +
          " / " + task.stats.ep_warmup_estimated_key_count + ")";
      break;
      case "loading data":
        message += " (" + task.stats.ep_warmup_value_count +
          " / " + task.stats.ep_warmup_estimated_value_count + ")";
      break;
    }
    return {key: task[keyName], status: message};
  });

  if (warmupTasks.length === 3 && originLength > 3) {
    rv.push({key: "more ...", status: ""});
  }

  return rv;
}
