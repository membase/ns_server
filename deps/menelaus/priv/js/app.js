//= require <jquery.js>
//= require <jqModal.js>
//= require <jquery.flot.js>
//= require <jquery.ba-bbq.js>
//= require <underscore.js>
//= require <tools.tabs.js>
//= require <jquery.cookie.js>
//= require <misc.js>
//= require <base64.js>
//= require <mkclass.js>
//= require <callbacks.js>
//= require <cells.js>
//= require <hash-fragment-cells.js>
//= require <right-form-observer.js>
//= require <app-misc.js>
//= require <core-data.js>
//= require <analytics.js>
//= require <manage-servers.js>
//= require <settings.js>

// TODO: doesn't work due to apparent bug in jqModal. Consider switching to another modal windows implementation
// $(function () {
//   $(window).keydown(function (ev) {
//     if (ev.keyCode != 0x1b) // escape
//       return;
//     console.log("got escape!");
//     // escape is pressed, now check if any jqModal window is active and hide it
//     _.each(_.values($.jqm.hash), function (modal) {
//       if (!modal.a)
//         return;
//       $(modal.w).jqmHide();
//     });
//   });
// });


var LogoutTimer = {
  reset: function () {
    if (this.timeoutId) {
      clearTimeout(this.timeoutId);
    }
    if (!DAO.login)
      return;
    this.timeoutId = setTimeout($m(this, 'onTimeout'), 300000);
  },
  onTimeout: function () {
    $.cookie('inactivity_reload', '1');
    DAO.setAuthCookie(null);
    $.cookie('fakeauth', null); /* for beta1 */
    reloadApp();
  }
};

var OverviewSection = {
  init: function () {
    this.active = new Cell(function (mode) {
      return mode == "overview"
    }).setSources({mode: DAO.cells.mode});

    this.alerts = new Cell(function (active) {
      var value = this.self.value;
      var params = {url: "/alerts"};
      return future.get(params);
    }).setSources({active: this.active});
    this.alerts.keepValueDuringAsync = true;
    renderCellTemplate(this.alerts, "overview_alert_list", function (v) {
      return v.list;
    });
    this.alerts.subscribe(function (cell) {
      // refresh every 30 seconds
      cell.recalculateAt((new Date()).valueOf() + 30000);
    });

    // var self = this;
    // _.defer(function () {
    //   BucketsSection.cells.detailedBuckets.subscribe($m(self, 'renderStatus'));
    // });
    // DAO.cells.currentPoolDetails.subscribe($m(self, 'onFreshNodeList'));
    // prepareTemplateForCell('server_list', DAO.cells.currentPoolDetails);
    // prepareTemplateForCell('cluster_status', DAO.cells.currentPoolDetails);
    // prepareTemplateForCell('pool_list', DAO.cells.poolList);
  },
  onEnter: function () {
  }
};

var BucketsSection = {
  cells: {},
  init: function () {
    var self = this;
    var cells = self.cells;

    cells.mode = DAO.cells.mode;

    cells.detailsPageURI = new Cell(function (poolDetails) {
      return poolDetails.buckets.uri;
    }).setSources({poolDetails: DAO.cells.currentPoolDetails});

    self.settingsWidget = new MultiDrawersWidget({
      hashFragmentParam: "buckets",
      template: "bucket_settings",
      placeholderCSS: '#buckets .settings-placeholder',
      elementsKey: 'name',
      drawerCellName: 'settingsCell',
      idPrefix: 'settingsRowID',
      actionLink: 'visitBucket',
      actionLinkCallback: function () {
        ThePage.ensureSection('buckets');
      },
      valueTransformer: function (bucketInfo, bucketSettings) {
        var rv = _.extend({}, bucketInfo, bucketSettings);
        delete rv.settingsCell;
        return rv;
      }
    });

    var poolDetailsValue;
    var clusterMemorySize = 0;
    DAO.cells.currentPoolDetails.subscribeValue(function (v) {
      if (!v)
        return;

      poolDetailsValue = v;
      clusterMemorySize = _.reduce(poolDetailsValue.nodes, 0, function (s, node) {
        return s + node.memoryTotal;
      });
    });

    var bucketsListTransformer = function (values) {
      self.buckets = values;
      _.each(values, function (bucket) {
        bucket.serversCount = poolDetailsValue.nodes.length;
        bucket.totalSize = bucket.totalSizeMB * 1048576;
        bucket.clusterMemorySize = clusterMemorySize;

        bucket.clusterFreeSize = bucket.clusterMemorySize - bucket.totalSize;

        bucket.clusterUsedPercent = bucket.totalSize * 100 / bucket.clusterMemorySize;
      });
      values = self.settingsWidget.valuesTransformer(values);
      return values;
    }
    cells.detailedBuckets = new Cell(function (pageURI) {
      return future.get({url: pageURI}, bucketsListTransformer, this.self.value);
    }).setSources({pageURI: cells.detailsPageURI});

    renderCellTemplate(cells.detailedBuckets, 'bucket_list');

    self.settingsWidget.hookRedrawToCell(cells.detailedBuckets);
  },
  buckets: null,
  refreshBuckets: function (callback) {
    var cell = this.cells.detailedBuckets;
    if (callback) {
      cell.changedSlot.subscribeOnce(callback);
    }
    cell.invalidate();
  },
  withBucket: function (uri, body) {
    if (!this.buckets)
      return;
    var buckets = this.buckets || [];
    var bucketInfo = _.detect(buckets, function (info) {
      return info.uri == uri;
    });

    if (!bucketInfo) {
      console.log("Not found bucket for uri:", uri);
      return null;
    }

    return body.call(this, bucketInfo);
  },
  findBucket: function (uri) {
    return this.withBucket(uri, function (r) {return r});
  },
  showBucket: function (uri) {
    this.withBucket(uri, function (bucketDetails) {
      var values = _.extend({}, bucketDetails, bucketDetails.settingsCell.value);
      var uri = function (data, cb) {
        alert('posted!');
        return cb('', 'success');
      }
      runFormDialog(uri, 'bucket_details_dialog', {
        initialValues: values
      });
    });
  },
  startFlushCache: function (uri) {
    hideDialog('bucket_details_dialog_container');
    this.withBucket(uri, function (bucket) {
      renderTemplate('flush_cache_dialog', {bucket: bucket});
      showDialog('flush_cache_dialog_container');
    });
  },
  completeFlushCache: function (uri) {
    hideDialog('flush_cache_dialog_container');
    this.withBucket(uri, function (bucket) {
      $.post(bucket.flushCacheUri);
    });
  },
  getPoolNodesCount: function () {
    return DAO.cells.currentPoolDetails.value.nodes.length;
  },
  onEnter: function () {
    this.refreshBuckets();
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  },
  onLeave: function () {
    this.settingsWidget.reset();
  },
  domId: function (sec) {
    if (sec == 'monitor_buckets')
      return 'buckets';
    return sec;
  },
  checkFormChanges: function () {
    var parent = $('#add_new_bucket_dialog');

    var cache = parent.find('[name=cacheSize]').val();
    if (cache != this.lastCacheValue) {
      this.lastCacheValue = cache;

      var cacheValue;
      if (/^\s*\d+\s*$/.exec(cache)) {
        cacheValue = parseInt(cache, 10);
      }

      var detailsText;
      if (cacheValue != undefined) {
        var nodesCnt = this.getPoolNodesCount();
        detailsText = [" MB x ",
                       nodesCnt,
                       " server nodes = ",
                       ViewHelpers.formatQuantity(cacheValue * nodesCnt * 1024 *1024),
                       " Total Cache Size/",
                       // TODO: will probably die
                       ViewHelpers.formatQuantity(OverviewSection.clusterMemoryAvailable),
                       " Cluster Memory Available"].join('')
      } else {
        detailsText = "";
      }
      parent.find('.cache-details').html(escapeHTML(detailsText));
    }
  },
  startCreate: function () {
    var parent = $('#add_new_bucket_dialog');

    var inputs = parent.find('input[type=text]');
    inputs = inputs.add(parent.find('input[type=password]'));
    inputs.val('');
    $('#add_new_bucket_errors_container').empty();
    this.lastCacheValue = undefined;

    var observer = parent.observePotentialChanges($m(this, 'checkFormChanges'));

    parent.find('form').bind('submit', function (e) {
      e.preventDefault();
      BucketsSection.createSubmit();
    });

    parent.find('[name=cacheSize]').val('64');

    showDialog(parent, {
      onHide: function () {
        observer.stopObserving();
        parent.find('form').unbind();
      }});
  },
  finishCreate: function () {
    hideDialog('add_new_bucket_dialog');
    nav.go('buckets');
  },
  createSubmit: function () {
    var self = this;
    var form = $('#add_new_bucket_form');

    $('#add_new_bucket_errors_container').empty();
    var loading = overlayWithSpinner(form);

    postWithValidationErrors(self.cells.detailsPageURI.value, form, function (data, status) {
      if (status == 'error') {
        loading.remove();
        renderTemplate("add_new_bucket_errors", data);
      } else {
        DAO.cells.currentPoolDetails.invalidate(function () {
          loading.remove();
          self.finishCreate();
        });
      }
    });
  },
  // TODO: currently inaccessible from UI
  startRemovingBucket: function () {
    if (!this.currentlyShownBucket)
      return;

    hideDialog('bucket_details_dialog_container');

    $('#bucket_remove_dialog .bucket_name').text(this.currentlyShownBucket.name);
    showDialog('bucket_remove_dialog');
  },
  // TODO: currently inaccessible from UI
  removeCurrentBucket: function () {
    var self = this;

    var bucket = self.currentlyShownBucket;
    if (!bucket)
      return;

    hideDialog('bucket_details_dialog_container');

    var spinner = overlayWithSpinner('#bucket_remove_dialog');
    var modal = new ModalAction();
    $.ajax({
      type: 'DELETE',
      url: self.currentlyShownBucket.uri,
      success: continuation,
      errors: continuation
    });
    return;

    function continuation() {
      self.refreshBuckets(continuation2);
    }

    function continuation2() {
      spinner.remove();
      modal.finish();
      hideDialog('bucket_remove_dialog');
    }
  }
};

;(function () {
  var weekDays = "Sun Mon Tue Wed Thu Fri Sat".split(' ');
  var monthNames = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(' ');
  function _2digits(d) {
    d += 100;
    return String(d).substring(1);
  }

  window.formatAlertTStamp = function formatAlertTStamp(mseconds) {
    var date = new Date(mseconds);
    var rv = [weekDays[date.getDay()],
      ' ',
      monthNames[date.getMonth()],
      ' ',
      date.getDate(),
      ' ',
      _2digits(date.getHours()), ':', _2digits(date.getMinutes()), ':', _2digits(date.getSeconds()),
      ' ',
      date.getFullYear()];

    return rv.join('');
  }

  window.formatLogTStamp = function formatLogTStamp(mseconds) {
    var date = new Date(mseconds);
    var rv = [
      "<strong>",
      _2digits(date.getHours()), ':', _2digits(date.getMinutes()), ':', _2digits(date.getSeconds()),
      "</strong> - ",
      weekDays[date.getDay()],
      ' ',
      monthNames[date.getMonth()],
      ' ',
      date.getDate(),
      ', ',
      date.getFullYear()];

    return rv.join('');
  }
})();

function formatAlertType(type) {
  switch (type) {
  case 'warning':
    return "Warning";
  case 'attention':
    return "Needs Your Attention";
  case 'info':
    return "Informative";
  }
}

var AlertsSection = {
  renderAlertsList: function () {
    var value = this.alerts.value;
    renderTemplate('alert_list', _.clone(value.list).reverse());
  },
  changeEmail: function () {
    SettingsSection.gotoSetupAlerts();
  },
  init: function () {
    this.active = new Cell(function (mode) {
      return (mode == "alerts" || mode == "log") ? true : undefined;
    }).setSources({mode: DAO.cells.mode});

    this.alerts = new Cell(function (active) {
      var value = this.self.value;
      var params = {url: "/alerts"};
      return future.get(params);
    }).setSources({active: this.active});
    this.alerts.keepValueDuringAsync = true;
    prepareTemplateForCell("alert_list", this.alerts);
    this.alerts.subscribe($m(this, 'renderAlertsList'));
    this.alerts.subscribe(function (cell) {
      // refresh every 30 seconds
      cell.recalculateAt((new Date()).valueOf() + 30000);
    });

    this.alertTab = new TabsCell("alertsTab",
                                 "#alerts .tabs",
                                 "#alerts .panes > div",
                                 ["log", "list"]);

    _.defer(function () {
      SettingsSection.advancedSettings.subscribe($m(AlertsSection, 'updateAlertsDestination'));
    });

    this.logs = new Cell(function (active) {
      return future.get({url: "/logs"}, undefined, this.self.value);
    }).setSources({active: this.active});
    this.logs.subscribe(function (cell) {
      cell.recalculateAt((new Date()).valueOf() + 30000);
    });
    this.logs.subscribe($m(this, 'renderLogsList'));
    prepareTemplateForCell('alert_logs', this.logs);
  },
  renderLogsList: function () {
    renderTemplate('alert_logs', _.clone(this.logs.value.list).reverse());
  },
  updateAlertsDestination: function () {
    var cell = SettingsSection.advancedSettings.value;
    var who = ''
    if (cell && ('email' in cell)) {
      who = cell.email || 'nobody'
    }
    $('#alerts_email_setting').text(who);
  },
  onEnter: function () {
  },
  navClick: function () {
    if (DAO.cells.mode.value == 'alerts' ||
        DAO.cells.mode.value == 'log') {
      this.alerts.setValue(undefined);
      this.logs.setValue(undefined);
      this.alerts.recalculate();
      this.logs.recalculate();
    }
  },
  domId: function (sec) {
    return 'alerts';
  }
}
var DummySection = {
  onEnter: function () {}
};

var BreadCrumbs = {
  update: function () {
    var sec = DAO.cells.mode.value;
    var path = [];

    function pushSection(name) {
      var el = $('#switch_' + name);
      path.push([el.text(), el.attr('href')]);
    }

    var container = $('.bread_crumbs > ul');
    container.html('');

    $('.currentNav').removeClass('currentNav');
    $('#switch_' + sec).addClass('currentNav');

    // TODO: Revisit bread-crumbs for server-specific or bucket-specific drill-down screens.
    //
    return;

    if (sec == 'analytics' && DAO.cells.statsBucketURL.value) {
      pushSection('buckets')
      var bucketInfo = DAO.cells.currentStatTargetCell.value;
      if (bucketInfo) {
        path.push([bucketInfo.name, '#visitBucket='+bucketInfo.uri]);
      }
    } else
      pushSection(sec);

    _.each(path.reverse(), function (pair) {
      var name = pair[0];
      var href = pair[1];

      var li = $('<li></li>');
      var a = $('<a></a>');
      a.attr('href', href);
      a.text(name);

      li.prepend(a);

      container.prepend(li);
    });

    container.find(':first-child').addClass('nobg');
  },
  init: function () {
    var cells = DAO.cells;
    var update = $m(this, 'update');

    cells.mode.subscribe(update);
    cells.statsBucketURL.subscribe(update);
    cells.currentStatTargetCell.subscribe(update);
  }
};

var ThePage = {
  sections: {overview: OverviewSection,
             servers: ServersSection,
             analytics: AnalyticsSection,
             buckets: BucketsSection,
             alerts: AlertsSection,
             log: AlertsSection,
             settings: SettingsSection,
             monitor_buckets: BucketsSection,
             monitor_servers: OverviewSection},

  coming: {monitor_buckets:true, monitor_servers:true, settings:true},

  currentSection: null,
  currentSectionName: null,
  signOut: function () {
    $.cookie('auth', null);
    $.cookie('fakeauth', null); /* for beta1 */
    reloadApp();
  },
  ensureSection: function (section) {
    if (this.currentSectionName != section)
      this.gotoSection(section);
  },
  gotoSection: function (section) {
    if (!(this.sections[section])) {
      throw new Error('unknown section:' + section);
    }
    if (this.currentSectionName == section) {
      if ('navClick' in this.currentSection)
        this.currentSection.navClick();
      else
        this.currentSection.onEnter();
    } else
      setHashFragmentParam('sec', section);
  },
  initialize: function () {
    _.each(_.uniq(_.values(this.sections)), function (sec) {
      if (sec.init)
        sec.init();
    });
    BreadCrumbs.init();

    DAO.onReady(function () {
      if (DAO.login) {
        $('.sign-out-link').show();
      }
    });

    var self = this;
    watchHashParamChange('sec', 'servers', function (sec) {
      var oldSection = self.currentSection;
      var currentSection = self.sections[sec];
      if (!currentSection) {
        self.gotoSection('overview');
        return;
      }
      self.currentSectionName = sec;
      self.currentSection = currentSection;

      DAO.switchSection(sec);

      var secId = sec;
      if (currentSection.domId != null) {
        secId = currentSection.domId(sec);
      }

      if (self.coming[sec] == true && window.location.href.indexOf("FORCE") < 0) {
        secId = 'coming';
      }

      $('#mainPanel > div:not(.notice)').css('display', 'none');
      $('#'+secId).css('display','block');

      // Allow reuse of same section DOM for different contexts, via CSS.
      // For example, secId might be 'buckets' and sec might by 'monitor_buckets'.
      $('#'+secId)[0].className = sec;

      _.defer(function () {
        if (oldSection && oldSection.onLeave)
          oldSection.onLeave();
        self.currentSection.onEnter();
        $(window).trigger('sec:' + sec);
      });
    });
  }
};

function hideAuthForm() {
  $(document.body).removeClass('auth');
}

function loginFormSubmit() {
  var login = $('#login_form [name=login]').val();
  var password = $('#login_form [name=password]').val();
  var spinner = overlayWithSpinner('#login_form', false);
  $('#login_form').addClass('noform');
  DAO.performLogin(login, password, function (status) {
    spinner.remove();
    $('#login_form').removeClass('noform');

    if (status == 'success') {
      hideAuthForm();
      $.cookie('fakeauth', "1");
      return;
    }

    $('#auth_failed_message').show();
  });
  return false;
}

window.nav = {
  go: $m(ThePage, 'gotoSection')
};

$(function () {
  $(document.body).removeClass('nojs');
  $(document.body).addClass('auth');

  _.defer(function () {
    var e = $('#auth_dialog [name=login]').get(0);
    try {e.focus();} catch (ex) {}
  });

  if ($.cookie('inactivity_reload')) {
    $.cookie('inactivity_reload', null);
    $('#auth_inactivity_message').show();
  }

  if ($.cookie('cluster_join_flash')) {
    $.cookie('cluster_join_flash', null);
    displayNotice('You have successfully joined the cluster');
  }
  if ($.cookie('ri')) {
    var reloadInfo = $.cookie('ri');
    var ts;

    var now = (new Date()).valueOf();
    if (reloadInfo) {
      ts = parseInt(reloadInfo);
      if ((now - ts) > 2*1000) {
        $.cookie('ri', null);
      }
    }
    displayNotice('An error was encountered when requesting data from the server.  ' +
		  'The console has been reloaded to attempt to recover.  There ' +
		  'may be additional information about the error in the log.');
  }

  ThePage.initialize();

  DAO.onReady(function () {
    $(window).trigger('hashchange');
  });

  $('#server_list_container .expander, #server_list_container .name').live('click', function (e) {
    var container = $('#server_list_container');
    var mydetails = $(e.target).parents("#server_list_container .primary").next();
    var opened = mydetails.hasClass('opened');

    mydetails.toggleClass('opened', !opened);
    mydetails.prev().find(".expander").toggleClass('expanded', !opened);
  });

  var spinner = overlayWithSpinner('#login_form', false);
  try {
    var noAuthStatus = DAO.tryNoAuthLogin();
    if (DAO.initStatus != "done") {
      hideAuthForm();
    } else if (noAuthStatus && $.cookie('fakeauth') == "1") { /* fakeauth is a workaround for deciding to not do auth in beta1 */
      hideAuthForm();
    }
  } finally {
    try {
      spinner.remove();
    } catch (__ignore) {}
  }
});

$(window).bind('template:rendered', function () {
  $('table.lined_tab tr:has(td):odd').addClass('highlight');
});

$('.remove_bucket').live('click', function() {
  BucketsSection.startRemovingBucket();
});

function showAbout() {
  function updateVersion() {
    var components = DAO.componentsVersion;
    if (components)
      $('#about_versions').text("Version: " + components['ns_server']);
    else {
      $.get('/versions', function (data) {
        DAO.componentsVersion = data.componentsVersion;
        updateVersion();
      }, 'json')
    }
  }
  updateVersion();
  showDialog('about_server_dialog');
}

function showInitDialog(page, opt) {
  $('.page-header').hide();

  opt = opt || {};

  var pages = [ "welcome", "resources", "cluster", "secure" ];

  if (page == "")
    page = "welcome";

  if (DAO.initStatus == "done") // If our current initStatus is already "done",
    page = "done";              // then don't let user go back through init dialog.

  for (var i = 0; i < pages.length; i++) {
    if (page == pages[i]) {
      if (NodeDialog["startPage_" + page]) {
        NodeDialog["startPage_" + page]('Self', 'init_' + page, opt);
      }
      $(document.body).addClass('init_' + page);
    }
  }

  for (var i = 0; i < pages.length; i++) { // Hide in a 2nd loop for more UI stability.
    if (page != pages[i]) {
      $(document.body).removeClass('init_' + pages[i]);
    }
  }

  if (page == "done")
    $('.page-header').show();

  if (DAO.initStatus != page) {
    DAO.initStatus = page;
    $.ajax({
      type:'POST', url:'/node/controller/initStatus', data: 'value=' + page
    });
  }
}

var NodeDialog = {
  submitClusterForm: function (e) {
    if (e)
      e.preventDefault();

    var form = $('#init_cluster_form');

    if ($('#no-join-cluster')[0].checked)
      return showInitDialog('secure');

    var errorsContainer = form.parent().find('.join_cluster_dialog_errors_container');
    errorsContainer.hide();

    var data = ServersSection.validateJoinClusterParams(form);
    if (data.length) {
      renderTemplate('join_cluster_dialog_errors', data, errorsContainer[0]);
      errorsContainer.show();
      return;
    }

    var hostname = data.hostname;
    data.clusterMemberHostIp = hostname;
    data.clusterMemberPort = '8080';
    if (hostname.indexOf(':') >= 0) {
      var arr = hostname.split(':');
      data.clusterMemberHostIp = arr[0];
      data.clusterMemberPort = arr[1];
    }
    delete data.hostname;

    var overlay = overlayWithSpinner($('#init_cluster_dialog'), '#EEE');
    postWithValidationErrors('/node/controller/doJoinCluster', $.param(data), function (errors, status) {
      if (status != 'success') {
        overlay.remove();
        renderTemplate('join_cluster_dialog_errors', errors, errorsContainer[0]);
        errorsContainer.show();
        return;
      }

      DAO.setAuthCookie(data.user, data.password);
      $.cookie('cluster_join_flash', 1);
      _.delay(function () {
        DAO.tryNoAuthLogin();
        overlay.remove();
      }, 5000);
    }, {
      timeout: 8000
    });
  },
  startMemoryDialog: function (node) {
    var parentName = '#edit_server_memory_dialog';

    $(parentName + ' .quota_error_message').hide();

    $.ajax({
      type:'GET', url:'/nodes/' + node, dataType: 'json', async: false,
      success: cb, error: cb});

    function cb(data, status) {
      if (status == 'success') {
        var m = data['memoryQuota'];
        if (m == null || m == "none") {
          m = "";
        }

        $(parentName).find('[name=quota]').val(m);
      }
    }

    $(parentName + ' button.save_button').click(function (e) {
        e.preventDefault();

        $(parentName + ' .quota_error_message').hide();

        var m = $(parentName).find('[name=quota]').val() || "";
        if (m == "") {
          m = "none";
        }

        $.ajax({
          type:'POST', url:'/nodes/' + node + '/controller/settings',
          data: 'memoryQuota=' + m,
          async:false, success:cbPost, error:cbPost
        });

        function cbPost(data, status) {
          if (status == 'success') {
            $(parentName).jqmHide();

            showInitDialog("resources"); // Same screen used in init-config wizard.
          } else {
            $(parentName + ' .quota_error_message').show();
          }
        }
      });

    showDialog('edit_server_memory_dialog');
  },

  startAddLocationDialog : function (node, storageKind) {
    var parentName = '#add_storage_location_dialog';

    $(parentName + ' .storage_location_error_message').hide();

    $(parentName).find('input[type=text]').val();

    $(parentName + ' button.save_button').click(function (e) {
        e.preventDefault();

        $(parentName + ' .storage_location_error_message').hide();

        var p = $(parentName).find('[name=path]').val() || "";
        var q = $(parentName).find('[name=quota]').val() || "none";

        $.ajax({
          type:'POST', url:'/nodes/' + node + '/controller/resources',
          data: 'path=' + p + '&quota=' + q + '&kind=' + storageKind,
          async:false, success:cbPost, error:cbPost
        });

        function cbPost(data, status) {
          if (status == 'success') {
            $(parentName).jqmHide();

            showInitDialog("resources");
          } else {
            $(parentName + ' .storage_location_error_message').show();
          }
        }
      });

    $(parentName + ' .add_storage_location_title').text("Add " + storageKind.toUpperCase() + " Storage Location");

    showDialog('add_storage_location_dialog');
  },

  startRemoveLocationDialog : function (node, path) {
    if (confirm("Are you sure you want to remove the storage location: " + path + "?  " +
                "Click OK to Remove.")) {
      $.ajax({
        type:'DELETE',
        url:'/nodes/' + node + '/resources/' + encodeURIComponent(path),
        async:false
      });

      showInitDialog("resources"); // Same screen used in init-config wizard.
    }
  },

  // The pagePrefix looks like 'init_license', and allows reusability.
  startPage_license: function(node, pagePrefix, opt) {
    var parentName = '#' + pagePrefix + '_dialog';

    opt = opt || {};

    $(parentName + ' .license_failed_message').hide();

    $.ajax({
      type:'GET', url:'/nodes/' + node, dataType: 'json', async: false,
      success: cb, error: cb});

    function cb(data, status) {
      if (status == 'success') {
        var lic = data.license;
        if (lic == null || lic == "") {
          lic = "2372AA-F32F1G-M3SA01"; // Hardcoded BETA license.
        }

        $(parentName).find('[name=license]').val(lic);
      }
    }

    var submitSelector = opt['submitSelector'] || 'input.next';

    $(parentName + ' ' + submitSelector).click(function (e) {
        e.preventDefault();

        $(parentName + ' .license_failed_message').hide();

        var license = $(parentName).find('[name=license]').val() || "";

        $.ajax({
          type:'POST', url:'/nodes/' + node + '/controller/settings',
          data: 'license=' + license,
          async:false, success:cbPost, error:cbPost
        });

        function cbPost(data, status) {
          if (status == 'success') {
            if (opt['successFunc'] != null) {
              opt['successFunc'](node, pagePrefix);
            } else {
              showInitDialog(opt["successNext"] || "resources");
            }
          } else {
            $(parentName + ' .license_failed_message').show();
          }
        }
      });
  },
  startPage_resources: function(node, pagePrefix, opt) {
    var parentName = '#' + pagePrefix + '_dialog';

    $('#init_resources_errors_container').html('');

    opt = opt || {};

    $.ajax({
      type:'GET', url:'/nodes/' + node, dataType: 'json', async: false,
      success: cb, error: cb});

    function cb(data, status) {
      data['node'] = data['node'] || node;

      NodeDialog.resourceNode = data;

      if (status == 'success') {
        renderTemplate('resource_panel', data);
      }
    }
  },
  submitResources: function () {
    var quota = $('#init_resources_form input[name=dynamic-ram-quota]').val();

    $('#init_resources_errors_container').html('');

    postWithValidationErrors('/nodes/Self/controller/settings',
                             $.param({memoryQuota: quota}),
                             continuation,
                             {async: false});

    function continuation(data, textStatus) {
      if (textStatus == 'error') {
        renderTemplate('init_resources_errors', data);
        $('#init_resources_form input[name=dynamic-ram-quota]')[0].focus();
        return;
      }
      showInitDialog('cluster');
    }
  },
  startPage_secure: function(node, pagePrefix, opt) {
    var parentName = '#' + pagePrefix + '_dialog';

    var form = $(parentName + ' form').unbind('submit');
    form.submit(function (e) {
      e.preventDefault();

      var parent = $(parentName)

      var user = parent.find('[name=username]').val();
      var pw = parent.find('[name=password]').val();
      var vpw = parent.find('[id=secure-password-verify]').val();
      if (pw == null || pw == "") {
        genericDialog({
          header: 'Please try again',
          text: 'Empty password is not allowed',
          buttons: {cancel: false, ok: true}
        });
        return;
      }
      if (pw !== vpw) {
        genericDialog({
          header: 'Please try again',
          text: 'Password and Verify Password do not match',
          buttons: {cancel: false, ok: true}
        });
        return;
      }

      SettingsSection.processSave(this, function (dialog) {
        // temporarily turned off. Bug 1407
        // DAO.login = user;
        // DAO.password = pw;
        showInitDialog('done');

        if (user != null && user != "") {
          $('.sign-out-link').show();
        }

        dialog.close();
      });
    });
  },
  startPage_cluster: function () {
    _.defer(function () {
      if ($('#join-cluster')[0].checked)
        $('.login-credentials').show();
    });
  }
};

NodeDialog.startPage_welcome = NodeDialog.startPage_license;

function displayNotice(text) {
  var div = $('<div></div>');
  var tname = 'notice';
  if (text.indexOf('error') >= 0) {
    tname = 'noticeErr';
  }
  renderTemplate(tname, {text: text}, div.get(0));
  $('#notice_container').prepend(div.children());
}

$('.notice').live('click', function () {
  $(this).fadeOut('fast');
});

$('.tooltip').live('click', function (e) {
  e.preventDefault();

  var jq = $(this);
  if (jq.hasClass('active_tooltip')) {
    return;
  }

  jq.addClass('active_tooltip');
  var msg = jq.find('.tooltip_msg')
  msg.hide().fadeIn('slow', function () {this.removeAttribute('style')});

  function resetEffects() {
    msg.stop();
    msg.removeAttr('style');
    if (timeout) {
      clearTimeout(timeout);
      timeout = undefined;
    }
  }

  function hide() {
    resetEffects();

    jq.removeClass('active_tooltip');
    jq.unbind();
  }

  var timeout;

  jq.bind('click', function (e) {
    e.stopPropagation();
    hide();
  })
  jq.bind('mouseout', function (e) {
    timeout = setTimeout(function () {
      msg.fadeOut('slow', function () {
        hide();
      });
    }, 250);
  })
  jq.bind('mouseover', function (e) {
    resetEffects();
  })
});

$(function () {
  var re = /javascript:nav.go\(['"](.*?)['"]\)/
  $("a[href^='javascript:nav.go(']").each(function () {
    var jq = $(this);
    var href = jq.attr('href');
    var match = re.exec(href);
    var section = match[1];
    jq.attr('href', '#sec=' + section);
  });
});

// clicks to links with href of '#<param>=' will be
// intercepted. Default action (navigating) will be prevented and body
// will be executed.
//
// Middle-clicks that open link in new tab/window will not be (and
// cannot be) intercepted
//
// We use this function to preserve other state that may be in url
// hash string in normal case, while still supporting middle-clicking.
function watchHashParamLinks(param, body) {
  param = '#' + param + '=';
  $('a').live('click', function (e) {
    var href = $(this).attr('href');
    if (href == null || href.slice(0,param.length) != param)
      return;
    e.preventDefault();
    body.call(this, e, href.slice(param.length));
  });
}
watchHashParamLinks('sec', function (e, href) {
  nav.go(href);
});

// used for links that do some action (like displaying certain bucket,
// dialog, ...). This function adds support for middle clicking on
// such action links.
function configureActionHashParam(param, body) {
  // this handles normal clicks (NOTE: no change to url/history is
  // done in that case)
  watchHashParamLinks(param, function (e, hash) {
    body(hash);
  });
  // this handles middle clicks. In such case the only hash fragment
  // of our url will be 'param'. We delete that param and call body
  DAO.onReady(function () {
    var value = getHashFragmentParam(param);
    if (value) {
      setHashFragmentParam(param, null);
      body(value, true);
    }
  });
}


// this handles memory -> disk quota sync on init wizard 1
$(function () {
  function onBlur() {
    var value = input.val();
    if (!value)
      input.val("unlimited");
  }
  function onFocus() {
    var value = input.val();
    if (value == "unlimited")
      input.val("");
  }

  var resourcePanel = $('#resource_panel_container');
  var observer;
  var input;
  var observedValue;

  var oldBound = [];

  function valueObserver() {
    var value = input.val();
    if (observedValue == value)
      return;
    observedValue = value;
    if (value == 'unlimited')
      value = '';
    if (!(/^[0-9]+$/.exec(value))) {
      value = '';
    } else {
      var intValue = parseInt(value, 10) * 1048576;
      var otherValue = NodeDialog.resourceNode.storage.hdd[0].diskStats.sizeKBytes * 1024;
      var t = ViewHelpers.prepareQuantity(otherValue, 1024);
      value = [truncateTo3Digits(intValue/t[0]), ' ', t[1], 'B'].join('');
    }
    resourcePanel.find('input[name=memoryQuota]').val(value);
  }

  $(window).bind('template:rendered', function () {
    var oldInput = input;

    input = resourcePanel.find('input[name=dynamic-ram-quota]');
    if (!input.length)
      return;

    if (oldInput) {
      _.each(oldBound, function (pair) {
        oldInput.unbind.apply(input, pair);
      });
    }

    if (observer)
      observer.stopObserving();

    observer = resourcePanel.observePotentialChanges(valueObserver);

    oldBound = [
      ['focus', onFocus],
      ['blur', onBlur]
    ];

    _.each(oldBound, function (pair) {
      input.bind.apply(input, pair);
    });
  });
});
