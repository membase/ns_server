function addBasicAuth(xhr, login, password) {
  var auth = 'Basic ' + Base64.encode(login + ':' + password);
  xhr.setRequestHeader('Authorization', auth);
}

function onUnexpectedXHRError(xhr, xhrStatus, errMsg) {
  window.onUnexpectedXHRError = function () {}

  if (Abortarium.isAborted(xhr))
    return;

  // for manual interception
  if ('debuggerHook' in onUnexpectedXHRError) {
    onUnexpectedXHRError['debuggerHook'](xhr, xhrStatus, errMsg);
  }

  var status;
  try {status = xhr.status} catch (e) {};

  if (status == 401) {
    $.cookie('auth', null);
    return reloadApp();
  }

  if ('JSON' in window && 'sessionStorage' in window) {
    var self = this;
    (function () {
      var json;
      var responseText;
      try {responseText = String(xhr.responseText)} catch (e) {};
      try {
        var s = {};
        _.each(self, function (value, key) {
          if (_.isString(key) || _.isNumber(key))
            s[key] = value;
        });
        json = JSON.stringify(s);
      } catch (e) {
        json = ""
      }
      sessionStorage.reloadCause = "s: " + json
        + "\nxhrStatus: " + xhrStatus + ",\nerrMsg: " + errMsg
        + ",\nstatusCode: " + status + ",\nresponseText:\n" + responseText;
      sessionStorage.reloadTStamp = (new Date()).valueOf();
    })();
  }

  var reloadInfo = $.cookie('ri');
  var ts;

  var now = (new Date()).valueOf();
  if (reloadInfo) {
    ts = parseInt(reloadInfo);
    if ((now - ts) < 15*1000) {
      $.cookie('rf', null); // clear reload-info cookie, so that
                            // manual reload don't cause 'console has
                            // been reloaded' flash message

      var details = DAO.cells.currentPoolDetailsCell.value;
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
  beforeSend: function (xhr, options) {
    if (DAO.login) {
      addBasicAuth(xhr, DAO.login, DAO.password);
    }
    xhr.setRequestHeader('invalid-auth-response', 'on');
    xhr.setRequestHeader('Cache-Control', 'no-cache');
    xhr.setRequestHeader('Pragma', 'no-cache');
    if (!options || !options.pushRequest)
      LogoutTimer.reset();
  },
  dataFilter: function (data, type) {
    if (type == "json" && data == "")
      throw new Error("empty json");
    return data;
  }
});

var DAO = {
  ready: false,
  version: undefined,
  cells: {},
  onReady: function (thunk) {
    if (DAO.ready)
      thunk.call(null);
    else
      $(window).one('dao:ready', function () {thunk();});
  },
  setAuthCookie: function (user, password) {
    if (user != '') {
      var auth = Base64.encode([user, ':', password].join(''))
      $.cookie('auth', auth);
    } else {
      $.cookie('auth', null);
    }
  },
  appendedVersion: false,
  loginSuccess: function (data) {
    var rows = data.pools;

    if (data.implementationVersion) {
      DAO.version = data.implementationVersion;
      DAO.componentsVersion = data.componentsVersion;
      if (!DAO.appendedVersion) {
        document.title = document.title + " (" + data.implementationVersion + ")"
        $('.version > .membase-version').text(String(data.implementationVersion)).parent().show();
        DAO.appendedVersion = true
      }
    }

    var provisioned = !!rows.length;
    var authenticated = data.isAdminCreds;
    if (provisioned && !authenticated)
      return false;

    if (provisioned && authenticated && !DAO.login) {
      alert("WARNING: Your browser has cached administrator Basic HTTP authentication credentials. You need to close and re-open it to clear that cache.");
    }

    DAO.ready = true;
    $(window).trigger('dao:ready');

    DAO.cells.poolList.setValue(rows);
    DAO.setAuthCookie(DAO.login, DAO.password);

    $('#secure_server_buttons').attr('class', DAO.login ? 'secure_disabled' : 'secure_enabled');


    // If the cluster appears to be configured, then don't let user go
    // back through init dialog.
    showInitDialog(provisioned ? 'done' : '');

    return true;
  },
  switchSection: function (section) {
    DAO.switchedSection = section;
    if (DAO.sectionsEnabled)
      DAO.cells.mode.setValue(section);
  },
  enableSections: function () {
    DAO.sectionsEnabled = true;
    DAO.cells.mode.setValue(DAO.switchedSection);
  },
  tryNoAuthLogin: function () {
    $.ajax({
      type: 'GET',
      url: "/pools",
      dataType: 'json',
      async: false,
      success: cb,
      error: cb});

    var rv;
    var auth;

    if (!rv && (auth = $.cookie('auth'))) {
      var arr = Base64.decode(auth).split(':');
      DAO.login = arr[0];
      DAO.password = arr[1];

      $('#auth_dialog [name=login]').val(arr[0]);

      $.ajax({
        type: 'GET',
        url: "/pools",
        dataType: 'json',
        async: false,
        success: cb,
        error: cb});
    }

    return rv;

    function cb(data, status) {
      if (status == 'success') {
        rv = DAO.loginSuccess(data);
      }
    }
  },
  performLogin: function (login, password, callback) {
    this.login = login;
    this.password = password;

    function cb(data, status) {
      if (status == 'success') {
        if (!DAO.loginSuccess(data))
          status = 'error';
      }
      if (callback)
        callback(status);
    }

    $.ajax({
      type: 'GET',
      url: "/pools",
      dataType: 'json',
      success: cb,
      error: cb});
  }
};


;(function () {
  this.mode = new Cell();
  this.poolList = new Cell();

  // this cell lowers comet/push timeout for overview sections _and_ makes
  // sure we don't fetch pool details if mode is not set (we're in
  // wizard)
  var poolDetailsPushTimeoutCell = new Cell(function (mode) {
    if (mode == 'overview')
      return 3000;
    return 20000;
  }, {
    mode: this.mode
  });

  this.currentPoolDetailsCell = Cell.mkCaching(function (poolList, pushTimeout) {
    if (!poolList[0])
      return;

    var url = poolList[0].uri;
    function poolDetailsValueTransformer(data) {
      // we clear pool's name to display empty name in analytics
      data.name = '';
      return data;
    }
    return future.getPush({url: url, stdErrorMarker: true},
                          poolDetailsValueTransformer, this.self.value, pushTimeout);
  }, {
    poolList: this.poolList,
    pushTimeout: poolDetailsPushTimeoutCell
  });
  this.currentPoolDetailsCell.equality = _.isEqual;

  this.nodeStatusesCell = Cell.compute(function (v) {
    var details = v.need(DAO.cells.currentPoolDetailsCell);
    return future.get({url: details.nodeStatusesUri});
  });

}).call(DAO.cells);

;(function () {
  var hostnameComparator = mkComparatorByProp('hostname');
  var pendingEject = []; // nodes to eject on next rebalance
  var pending = []; // nodes for pending tab
  var active = []; // nodes for active tab
  var allNodes = []; // all known nodes

  var cell = DAO.cells.serversCell = new Cell(formula, {
    details: DAO.cells.currentPoolDetailsCell,
    detailsAreStale: (function (metaCell) {
      return Cell.compute(function (v) {return v.need(metaCell).stale;});
    })(DAO.cells.currentPoolDetailsCell.ensureMetaCell())
  });
  cell.propagateMeta = null;
  cell.metaCell = DAO.cells.currentPoolDetailsCell.ensureMetaCell();

  cell.cancelPendingEject = cancelPendingEject;

  function cancelPendingEject(node) {
    node.pendingEject = false;
    pendingEject = _.without(pendingEject, node);
    cell.invalidate();
  }

  function formula(details, detailsAreStale) {
    var self = this;

    var pending = [];
    var active = [];
    allNodes = [];

    var nodes = details.nodes;
    var nodeNames = _.pluck(nodes, 'hostname');
    _.each(nodes, function (n) {
      var mship = n.clusterMembership;
      if (mship == 'active')
        active.push(n);
      else
        pending.push(n);
      if (mship == 'inactiveFailed')
        active.push(n);
    });

    var stillActualEject = [];
    _.each(pendingEject, function (node) {
      var original = _.detect(nodes, function (n) {
        return n.otpNode == node.otpNode;
      });
      if (!original || original.clusterMembership == 'inactiveAdded') {
        return;
      }
      stillActualEject.push(original);
      original.pendingEject = true;
    });

    pendingEject = stillActualEject;

    pending = pending = pending.concat(pendingEject);
    pending.sort(hostnameComparator);
    active.sort(hostnameComparator);

    allNodes = _.uniq(active.concat(pending));

    var reallyActive = _.select(active, function (n) {
      return n.clusterMembership == 'active' && !n.pendingEject && n.status =='healthy';
    });

    if (reallyActive.length == 1) {
      reallyActive[0].lastActive = true;
    }

    _.each(allNodes, function (n) {
      n.ejectPossible = !detailsAreStale && !n.pendingEject;
      n.failoverPossible = !detailsAreStale && (n.clusterMembership != 'inactiveFailed');
      n.reAddPossible = !detailsAreStale && (n.clusterMembership == 'inactiveFailed' && n.status == 'healthy');

      var nodeClass = ''
      if (n.clusterMembership == 'inactiveFailed') {
        nodeClass = 'failed_over'
      } else if (n.status != 'healthy') {
        nodeClass = 'server_down'
      } else {
        nodeClass = 'status_up'
      }
      if (n.lastActive)
        nodeClass += ' last-active';
      n.nodeClass = nodeClass;
    });

    return {
      pendingEject: pendingEject,
      pending: pending,
      active: active,
      allNodes: allNodes
    }
  }
})();
