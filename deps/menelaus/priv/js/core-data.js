function addBasicAuth(xhr, login, password) {
  var auth = 'Basic ' + Base64.encode(login + ':' + password);
  xhr.setRequestHeader('Authorization', auth);
}

function onNoncriticalXHRError(xhr) {
  if (Abortarium.isAborted(xhr))
    return;

  var status;
  try {status = xhr.status} catch (e) {};

  // everything except timeout & service unavailable
  if (status != 503 && status != 504 && status > 0) {
    onUnexpectedXHRError(xhr);
    throw new Error("xhr error is critical");
  }

  // TODO: implement some UI for that and maybe some request repeating
  // policy too
  console.log("failed non-critical request");
}

function onUnexpectedXHRError(xhr) {
  window.onUnexpectedXHRError = function () {}

  if (Abortarium.isAborted(xhr))
    return;

  // for manual interception
  if ('debuggerHook' in onUnexpectedXHRError) {
    onUnexpectedXHRError['debuggerHook'](xhr);
  }

  var status;
  try {status = xhr.status} catch (e) {};

  if (status == 401) {
    $.cookie('auth', null);
    return reloadApp();
  }

  var reloadInfo = $.cookie('ri');
  var ts;

  var now = (new Date()).valueOf();
  if (reloadInfo) {
    ts = parseInt(reloadInfo);
    if ((now - ts) < 15*1000) {
      $.cookie('ri', null); // clear reload-info cookie, so that
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
  reloadAppWithDelay(500);
}

$.ajaxSetup({
  error: onUnexpectedXHRError,
  timeout: 5000,
  beforeSend: function (xhr) {
    if (DAO.login) {
      addBasicAuth(xhr, DAO.login, DAO.password);
    }
    xhr.setRequestHeader('invalid-auth-response', 'on');
    xhr.setRequestHeader('Cache-Control', 'no-cache');
    xhr.setRequestHeader('Pragma', 'no-cache');
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
    DAO.ready = true;
    $(window).trigger('dao:ready');
    var rows = data.pools;
    DAO.cells.poolList.setValue(rows);
    DAO.setAuthCookie(DAO.login, DAO.password);

    $('#secure_server_buttons').attr('class', DAO.login ? 'secure_disabled' : 'secure_enabled');

    if (data.implementationVersion) {
      DAO.version = data.implementationVersion;
      DAO.componentsVersion = data.componentsVersion;
      if (!DAO.appendedVersion) {
        document.title = document.title + " (" + data.implementationVersion + ")"
        DAO.appendedVersion = true
      }
    }

    DAO.initStatus = data.initStatus || "";
    showInitDialog(DAO.initStatus);
  },
  switchSection: function (section) {
    DAO.cells.mode.setValue(section);
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
        DAO.loginSuccess(data);
        rv = true;
      }
    }
  },
  performLogin: function (login, password, callback) {
    this.login = login;
    this.password = password;

    function cb(data, status) {
      if (status == 'success') {
        DAO.loginSuccess(data);
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
  },
  getBucketNodesCount: function (_dummy) {
    return DAO.cells.currentPoolDetailsCell.value.nodes.length;
  },
  isInCluster: function () {
    var details = DAO.cells.currentPoolDetails.value
    if (!details)
      return undefined;
    return details.nodes.length > 1;
  }
};


;(function () {
  this.mode = new Cell();
  this.poolList = new Cell();

  this.currentPoolDetailsCell = new Cell(function (poolList) {
    function poolDetailsValueTransformer(data) {
      // we clear pool's name to display empty name in analytics
      data.name = '';
      return data;
    }
    var uri = poolList[0].uri;
    return future.getPush({url: uri}, poolDetailsValueTransformer);
  }).setSources({poolList: this.poolList});
  this.currentPoolDetailsCell.equality = _.isEqual;

}).call(DAO.cells);

