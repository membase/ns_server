/**
   Copyright 2011 Couchbase, Inc.

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
var LogoutTimer = {
  reset: function () {
    if (this.timeoutId) {
      clearTimeout(this.timeoutId);
    }
    if (!DAL.login)
      return;
    this.timeoutId = setTimeout($m(this, 'onTimeout'), 300000);
  },
  onTimeout: function () {
    performSignOut();
  }
};

function performSignOut(isVoluntary) {
  if (ModalAction.isActive()) {
    $(window).one('modal-action:complete', function () {performSignOut()});
    return;
  }

  $(window).trigger('hashchange'); // this will close all dialogs

  DAL.setAuthCookie(null);
  DAL.cells.mode.setValue(undefined);
  DAL.cells.currentPoolDetailsCell.setValue(undefined);
  DAL.cells.poolList.setValue(undefined);
  DAL.ready = false;

  $(document.body).addClass('auth');
  if (!isVoluntary)
    $('#auth_inactivity_message').show();

  $('.sign-out-link').hide();
  DAL.onReady(function () {
    if (DAL.login)
      $('.sign-out-link').show();
  });

  _.defer(function () {
    var e = $('#auth_dialog [name=password]').get(0);
    try {e.focus();} catch (ex) {}
  });
}

;(function () {
  var weekDays = "Sun Mon Tue Wed Thu Fri Sat".split(' ');
  var monthNames = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(' ');
  function _2digits(d) {
    d += 100;
    return String(d).substring(1);
  }

  window.formatAlertTStamp = formatAlertTStamp;
  function formatAlertTStamp(mseconds) {
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
  };

  window.formatTime = function formatTime(mseconds) {
    var date = new Date(mseconds);
    var rv = [
      _2digits(date.getHours()), ':',
      _2digits(date.getMinutes()), ':',
      _2digits(date.getSeconds())];
    return rv.join('');
  };


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
  init: function () {
    var active = Cell.needing(DAL.cells.mode).compute(function (v, mode) {
      return (mode === "log") || undefined;
    });

    var logs = Cell.needing(active).compute(function (v, active) {
      return future.get({url: "/logs"});
    });
    logs.keepValueDuringAsync = true;
    logs.subscribe(function (cell) {
      cell.recalculateAfterDelay(30000);
    });

    this.logs = logs;

    var massagedLogs = Cell.compute(function (v) {
      var logsValue = v(logs);
      var stale = v.need(IOCenter.staleness);
      if (logsValue === undefined) {
        if (!stale)
          return;
        logsValue = {list: []};
      }
      return _.extend({}, logsValue, {stale: stale});
    });

    renderCellTemplate(massagedLogs, 'alert_logs', {
      valueTransformer: function (value) {
        var list = value.list || [];
        return _.clone(list).reverse();
      }
    });

    massagedLogs.subscribeValue(function (massagedLogs) {
      if (massagedLogs === undefined)
        return;
      var stale = massagedLogs.stale;
      $('#alerts .staleness-notice')[stale ? 'show' : 'hide']();
    });
  },
  onEnter: function () {
  },
  navClick: function () {
    if (DAL.cells.mode.value == 'log')
      this.logs.recalculate();
  },
  domId: function (sec) {
    return 'alerts';
  }
}
var DummySection = {
  onEnter: function () {}
};

var ThePage = {
  sections: {overview: OverviewSection,
             servers: ServersSection,
             analytics: AnalyticsSection,
             buckets: BucketsSection,
             log: AlertsSection,
             monitor_buckets: MonitorBucketsSection,
             monitor_servers: MonitorServersSection,
             settings: SettingsSection},

  coming: {alerts:true},

  currentSection: null,
  currentSectionName: null,
  signOut: function () {
    performSignOut(true);
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

    initAlertsSubscriber();

    DAL.cells.mode.subscribeValue(function (sec) {
      $('.currentNav').removeClass('currentNav');
      $('#switch_' + sec).addClass('currentNav');
    });

    DAL.onReady(function () {
      if (DAL.login) {
        $('.sign-out-link').show();
      }
    });

    var self = this;
    watchHashParamChange('sec', 'overview', function (sec) {
      var oldSection = self.currentSection;
      var currentSection = self.sections[sec];
      if (!currentSection) {
        self.gotoSection('overview');
        return;
      }
      self.currentSectionName = sec;
      self.currentSection = currentSection;

      DAL.switchSection(sec);

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
  $('#auth_dialog .alert_red').hide();
  $('#login_form').addClass('noform');
  DAL.performLogin(login, password, function (status) {
    spinner.remove();
    $('#login_form').removeClass('noform');

    if (status == 'success') {
      hideAuthForm();
      // don't keep credentials in DOM tree
      $('#login_form [name=password]').val('');
      return;
    }

    $('#auth_failed_message').show();
  });
  return false;
}

var NodeDialog = {
  panicAndReload: function() {
    alert('Failed to get initial setup data from server. Cannot continue.' +
          ' Would you like to attempt to reload the web console?  This may fail if the server is not running.');
    reloadApp();
  },
  doClusterJoin: function () {
    var form = $('#init_cluster_form');

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
    data.clusterMemberPort = '8091';
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

      DAL.setAuthCookie(data.user, data.password);
      DAL.tryNoAuthLogin();
      overlay.remove();
      displayNotice('This server has been associated with the cluster and will join on the next rebalance operation.');
    });
  },
  startPage_bucket_dialog: function () {
    var spinner;
    var timeout = setTimeout(function () {
      spinner = overlayWithSpinner('#init_bucket_dialog');
    }, 50);
    $.ajax({url: '/pools/default/buckets/default',
            success: continuation,
            error: continuation,
            dataType: 'json'});
    function continuation(data, status) {
      if (status != 'success') {
        $.ajax({type:'GET', url:'/nodes/self', dataType: 'json',
                error: function () {
                  NodeDialog.panicAndReload();
                },
                success: function (nodeData) {
                  data = {uri: '/pools/default/buckets',
                          bucketType: 'membase',
                          authType: 'sasl',
                          quota: { rawRAM: nodeData.storageTotals.ram.quotaTotal },
                          replicaNumber: 1};
                  continuation(data, 'success');
                }});
        return;
      }
      if (spinner)
        spinner.remove();
      clearTimeout(timeout);
      var initValue = _.extend(data, {
        uri: '/controller/setupDefaultBucket'
      });
      var dialog = new BucketDetailsDialog(initValue, true,
                                           {id: 'init_bucket_dialog',
                                            refreshBuckets: function (b) {b()},
                                            onSuccess: function () {
                                              dialog.cleanup();
                                              showInitDialog('update_notifications');
                                            }});
      var cleanupBack = dialog.bindWithCleanup($('#step-init-bucket-back'),
                                               'click',
                                               function () {
                                                 dialog.cleanup();
                                                 showInitDialog('cluster');
                                               });
      dialog.cleanups.push(cleanupBack);
      dialog.startForm();
    }
  },
  startPage_secure: function(node, pagePrefix, opt) {
    var parentName = '#' + pagePrefix + '_dialog';

    $(parentName + ' div.config-bottom button#step-4-finish').click(function (e) {
      e.preventDefault();
      $('#init_secure_form').submit();
    });
    $(parentName + ' div.config-bottom button#step-4-back').click(function (e) {
      e.preventDefault();
      showInitDialog("update_notifications");
    });

    var form = $(parentName + ' form').unbind('submit');
    _.defer(function () {
      $(parentName).find('[name=password]')[0].focus();
    });
    form.submit(function (e) {
      e.preventDefault();

      var parent = $(parentName)

      var user = parent.find('[name=username]').val();
      var pw = parent.find('[name=password]').val();
      var vpw = parent.find('[id=secure-password-verify]').val();
      if (pw == null || pw == "") {
        genericDialog({
          header: 'Please try again',
          text: 'A password of at least six characters is required.',
          buttons: {cancel: false, ok: true}
        });
        return;
      }
      if (pw !== vpw) {
        genericDialog({
          header: 'Please try again',
          text: '\'Password\' and \'Verify Password\' do not match',
          buttons: {cancel: false, ok: true}
        });
        return;
      }

      SettingsSection.processSave(this, function (dialog) {
        DAL.performLogin(user, pw, function () {
          showInitDialog('done');

          if (user != null && user != "") {
            $('.sign-out-link').show();
          }

          dialog.close();
        });
      });
    });
  },
  startPage_welcome: function(node, pagePrefix, opt) {
    $('#init_welcome_dialog input.next').click(function (e) {
      e.preventDefault();

      showInitDialog("cluster");
    });
  },

  startPage_cluster: function (node, pagePrefix, opt) {
    var dialog = $('#init_cluster_dialog');
    var resourcesObserver;

    $('#join-cluster').click(function (e) {
      $('.login-credentials').slideDown();
      $('.memory-quota').slideUp();
      $('#init_cluster_dialog_memory_errors_container').slideUp();
    });
    $('#no-join-cluster').click(function (e) {
      $('.memory-quota').slideDown();
      $('.login-credentials').slideUp();
    });

    // we return function signaling that we're not yet ready to show
    // our page of wizard (no data to display in the form), but will
    // be at one point. showInitDialog will call us immediately
    // passing us it's continuation. This is partial continuation to
    // be more precise
    return function (continueShowDialog) {
      dialog.find('.quota_error_message').hide();

      $.ajax({type:'GET', url:'/nodes/self', dataType: 'json',
              success: dataCallback, error: dataCallback});

      function dataCallback(data, status) {
        if (status != 'success') {
          return NodeDialog.panicAndReload();
        }

        // we have node data and can finally display our wizard page
        // and pre-fill the form
        continueShowDialog();

        $('#step-2-next').click(onSubmit);
        dialog.find('form').submit(onSubmit);

        _.defer(function () {
          if ($('#join-cluster')[0].checked)
            $('.login-credentials').show();
        });

        var m = data['memoryQuota'];
        if (m == null || m == "none") {
          m = "";
        }

        dialog.find('[name=quota]').val(m);

        data['node'] = data['node'] || node;

        var storageTotals = data.storageTotals;

        var totalRAMMegs = Math.floor(storageTotals.ram.total/Math.Mi);

        dialog.find('[name=dynamic-ram-quota]').val(Math.floor(storageTotals.ram.quotaTotal / Math.Mi));
        dialog.find('.ram-total-size').text(totalRAMMegs + ' MB');
        var ramMaxMegs = Math.max(totalRAMMegs - 1024,
                                  Math.floor(storageTotals.ram.total * 4 / (5 * Math.Mi)));
        dialog.find('.ram-max-size').text(ramMaxMegs);

        var firstResource = data.storage.hdd[0];
        var diskTotalGigs = Math.floor((storageTotals.hdd.total - storageTotals.hdd.used) / Math.Gi);
        var diskPath, diskTotal;

        diskTotal = dialog.find('.total-size');
        function updateDiskTotal() {
          diskTotal.text(escapeHTML(diskTotalGigs) + ' GB');
        }
        updateDiskTotal();
        (diskPath = dialog.find('[name=path]')).val(escapeHTML(firstResource.path));

        var prevPathValue;

        var hddResources = data.availableStorage.hdd;
        var mountPoints = new MountPoints(data, _.pluck(hddResources, 'path'));

        resourcesObserver = dialog.observePotentialChanges(function () {
          var pathValue = diskPath.val();

          if (pathValue == prevPathValue)
            return;

          prevPathValue = pathValue;
          if (pathValue == "") {
            diskTotalGigs = 0;
            updateDiskTotal();
            return;
          }

          var rv = mountPoints.lookup(pathValue);
          var pathResource = ((rv != null) && hddResources[rv]);

          if (!pathResource)
            pathResource = {path:"/", sizeKBytes: 0, usagePercent: 0};

          diskTotalGigs = Math.floor(pathResource.sizeKBytes * (100 - pathResource.usagePercent) / 100 / Math.Mi);
          updateDiskTotal();
        });
      }
    }

    // cleans up all event handles
    function onLeave() {
      $('#step-2-next').unbind();
      dialog.find('form').unbind();
      if (resourcesObserver)
        resourcesObserver.stopObserving();
    }

    function onSubmit(e) {
      e.preventDefault();

      dialog.find('.warning').hide();

      var p = dialog.find('[name=path]').val() || "";

      var m = dialog.find('[name=dynamic-ram-quota]').val() || "";
      if (m == "") {
        m = "none";
      }

      postWithValidationErrors('/nodes/' + node + '/controller/settings',
                               $.param({path: p}),
                               afterDisk);

      var diskArguments;

      function afterDisk() {
        // remember our arguments so that we can display validation
        // errors later. We're doing that to display validation errors
        // from memory quota and disk path posts simultaneously
        diskArguments = arguments;
        if ($('#no-join-cluster')[0].checked) {
          postWithValidationErrors('/pools/default',
                                   $.param({memoryQuota: m}),
                                   memPost);
          return;
        }

        if (handleDiskStatus.apply(null, diskArguments))
          NodeDialog.doClusterJoin();
      }

      function handleDiskStatus(data, status) {
        var ok = (status == 'success')
        if (!ok) {
          var errorContainer = dialog.find('.init_cluster_dialog_errors_container');
          errorContainer.text(data.join(' and '));
          errorContainer.css('display', 'block');
        }
        return ok;
      }

      function memPost(data, status) {
        var ok = handleDiskStatus.apply(null, diskArguments);

        if (status == 'success') {
          if (ok) {
            BucketsSection.refreshBuckets();
            showInitDialog("bucket_dialog");
            onLeave();
          }
        } else {
          var errorContainer = $('#init_cluster_dialog_memory_errors_container');
          errorContainer.text(data.join(' and '));
          errorContainer.css('display', 'block');
        }
      }
    }
  },
  startPage_update_notifications: function(node, pagePrefix, opt) {
    var dialog = $('#init_update_notifications_dialog');
    dialog.find('a.more_info').click(function(e) {
      e.preventDefault();
      dialog.find('p.more_info').slideToggle();
    });
    dialog.find('button.back').click(function (e) {
      e.preventDefault();
      onLeave();
      showInitDialog("bucket_dialog");
    });
    // Go to next page. Send off email address if given and apply settings
    dialog.find('button.next').click(function (e) {
      e.preventDefault();
      var email = $.trim($('#init-join-community-email').val());
      if (email!=='') {
        // Send email address. We don't care if notifications were enabled
        // or not.
        $.ajax({
          url: UpdatesNotificationsSection.remote.email,
          dataType: 'jsonp',
          data: {email: email}
        });
      }

      var sendStatus = $('#init-notifications-updates-enabled').is(':checked');
      postWithValidationErrors(
        '/settings/stats',
        $.param({sendStats: sendStatus}),
        function() {
          onLeave();
          showInitDialog("secure");
        }
      );
    });

    // cleans up all event handles
    function onLeave() {
      dialog.find('a.more_info').unbind();
      dialog.find('button.back').unbind();
      dialog.find('button.next').unbind();
    }
  }
};

$(function () {
  $(document.body).removeClass('nojs');

  _.defer(function () {
    var e = $('#auth_dialog [name=login]').get(0);
    try {e.focus();} catch (ex) {}
  });

  $('#login_form').bind('submit', function (e) {
    e.preventDefault();
    loginFormSubmit();
  });

  if ($.cookie('rf')) {
    displayNotice('An error was encountered when requesting data from the server.  ' +
                  'The console has been reloaded to attempt to recover.  There ' +
                  'may be additional information about the error in the log.');
    DAL.onReady(function () {
      $.cookie('rf', null);
      if ('sessionStorage' in window && window.sessionStorage.reloadCause) {
        var text = "Browser client XHR failure encountered. (age: "
          + ((new Date()).valueOf() - sessionStorage.reloadTStamp)+")  Diagnostic info:\n";
        postClientErrorReport(text + window.sessionStorage.reloadCause);
        delete window.sessionStorage.reloadCause;
        delete window.sessionStorage.reloadTStamp;
      }
    });
  }

  ThePage.initialize();

  DAL.onReady(function () {
    $(window).trigger('hashchange');
  });

  try {
    if (DAL.tryNoAuthLogin()) {
      hideAuthForm();
    }
  } finally {
    try {
      $('#auth_dialog .spinner').remove();
    } catch (__ignore) {}
  }

  if (!DAL.login && $('#login_form:visible').length) {
    var backdoor =
      (function () {
        var href = window.location.href;
        var match = /\?(.*?)(?:$|#)/.exec(href);
        var rv = false;
        if (match && /(&|^)na(&|$)/.exec(match[1]))
          rv = true;
        return rv;
      })();
    if (backdoor) {
      var login = $('#login_form [name=login]').val('Administrator');
      var password = $('#login_form [name=password]').val('asdasd');
      loginFormSubmit();
    }
  }
});

function showAbout() {
  function updateVersion() {
    var components = DAL.componentsVersion;
    if (components)
      $('#about_versions').text("Version: " + components['ns_server']);
    else {
      $.get('/versions', function (data) {
        DAL.componentsVersion = data.componentsVersion;
        updateVersion();
      }, 'json')
    }

    var poolDetails = DAL.cells.currentPoolDetailsCell.value || {nodes:[]};
    var nodesCount = poolDetails.nodes.length;
    if (nodesCount >= 0x100)
      nodesCount = 0xff;

    var buckets = DAL.cells.bucketsListCell.value || [];
    var bucketsCount = buckets.length;
    if (bucketsCount >= 100)
      bucketsCount = 99;

    var memcachedBucketsCount = _.filter(buckets, function (b) {return b.bucketType == 'memcache'}).length;
    var membaseBucketsCount = _.filter(buckets, function (b) {return b.bucketType == 'membase'}).length;

    if (memcachedBucketsCount >= 0x10)
      memcachedBucketsCount = 0xf;
    if (membaseBucketsCount >= 0x10)
      membaseBucketsCount = 0x0f;

    var date = (new Date());

    var magicString = [
      integerToString(0x100 + poolDetails.nodes.length, 16).slice(1)
        + integerToString(date.getMonth()+1, 16),
      integerToString(100 + bucketsCount, 10).slice(1)
        + integerToString(memcachedBucketsCount, 16),
      integerToString(membaseBucketsCount, 16)
        + date.getDate()
    ];
    $('#cluster_state_id').text('Cluster State ID: ' + magicString.join('-'));
  }
  updateVersion();
  showDialog('about_server_dialog',
      {title: $('#about_server_dialog .config-top').hide().html()});
}

function showInitDialog(page, opt, isContinuation) {
  opt = opt || {};

  var pages = [ "welcome", "update_notifications", "cluster", "secure",
    "bucket_dialog" ];

  if (page == "")
    page = "welcome";

  for (var i = 0; i < pages.length; i++) {
    if (page == pages[i]) {
      var rv;
      if (!isContinuation && NodeDialog["startPage_" + page]) {
        rv = NodeDialog["startPage_" + page]('self', 'init_' + page, opt);
      }
      // if startPage is in continuation passing style, call it
      // passing continuation and return.  This allows startPage to do
      // async computation and then resume dialog page switching
      if (rv instanceof Function) {
        $('body, html').css('cursor', 'wait');

        return rv(function () {

          $('body, html').css('cursor', '');
          // we don't pass real contination, we just call ourselves again
          showInitDialog(page, opt, true);
        });
      }
      $(document.body).addClass('init_' + page);
      _.defer(function () {
        var element = $('.focusme:visible').get(0)
        if (!element) {
          return;
        }
        try {element.focus();} catch (e) {}
      });
    }
  }

  $('.page-header')[page == 'done' ? 'show' : 'hide']();

  if (page == 'done')
    DAL.enableSections();

  for (var i = 0; i < pages.length; i++) { // Hide in a 2nd loop for more UI stability.
    if (page != pages[i]) {
      $(document.body).removeClass('init_' + pages[i]);
    }
  }

  if (page == 'done')
    return;

  var notices = [];
  $('#notice_container > *').each(function () {
    var text = $.data(this, 'notice-text');
    if (!text)
      return;
    notices.push(text);
  });
  if (notices.length) {
    $('#notice_container').html('');
    alert(notices.join("\n\n"));
  }
}

function displayNotice(text, isError) {
  var div = $('<div></div>');
  var tname = 'notice';
  if (isError || (isError === undefined && text.indexOf('error') >= 0)) {
    tname = 'noticeErr';
  }
  renderTemplate(tname, {text: text}, div.get(0));
  $.data(div.children()[0], 'notice-text', text);
  $('#notice_container').prepend(div.children());
  ThePage.gotoSection("overview");
}

$('.notice').live('click', function () {
  var self = this;
  $(self).fadeOut('fast', function () {
    $(self).remove();
  });
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

configureActionHashParam('visitSec', function (sec) {
  ThePage.gotoSection(sec);
});

$(function () {
  var container = $('.io-error-notice');
  var timeoutId;
  function renderStatus() {
    if (timeoutId != null)
      clearTimeout(timeoutId);

    var status = IOCenter.status.value;

    if (status.healthy) {
      container.hide();
      return;
    }

    container.show();

    if (status.repeating) {
      container.text('Repeating failed XHR request...');
      return
    }

    var now = (new Date()).getTime();
    var repeatIn = Math.max(0, Math.floor((status.repeatAt - now)/1000));
    container.html('Lost connection to server at ' + window.location.host + '. Repeating in ' + repeatIn + ' seconds. <a href="#">Retry now</a>');
    var delay = Math.max(200, status.repeatAt - repeatIn*1000 - now);
    timeoutId = setTimeout(renderStatus, delay);
  }

  container.find('a').live('click', function (e) {
    e.preventDefault();
    IOCenter.forceRepeat();
  });

  IOCenter.status.subscribeValue(renderStatus);
});

$(function () {
  if (!('AllImages' in window))
    return;
  var images = window['AllImages']

  var body = $(document.body);
  _.each(images, function (path) {
    var j = $(new Image());
    j[0].src = path;
    j.css('display', 'none');
    j.appendTo(body);
  });
});


// uses /pools/default to piggyback any user alerts we want to show
function initAlertsSubscriber() {

  var alertsShown = false,
      dialog = null,
      alerts = [];

  function addAlert(msg) {
    for (var i = 0; i < alerts.length; i++) {
      if (alerts[i].msg === msg) {
        return;
      }
    }
    var tstamp = "<strong>["+window.formatTime(new Date().getTime())+"]</strong>";
    alerts.push({msg: tstamp + " - " + msg});
  };

  function createAlertMsg() {
    for (var i = 0, msg =  ""; i < alerts.length; i++) {
      msg += alerts[i].msg + "<br />";
    }
    return (msg === "" && false) || msg;
  };

  DAL.cells.currentPoolDetailsCell.subscribeValue(function (sec) {

    if (sec && sec.alerts && sec.alerts.length > 0) {

      if (alertsShown) {
        dialog.close();
      }

      for (var i = 0; i < sec.alerts.length; i++) {
        addAlert(sec.alerts[i]);
      }

      alertsShown = true;
      var alertMsg = createAlertMsg();

      if (alertMsg) {
        dialog = genericDialog({
          buttons: {ok: true},
          header: "Alert",
          textHTML: alertMsg,
          callback: function (e, btn, dialog) {
            alerts = [];
            alertsShown = false;
            dialog.close();
          }
        });
      }
    }
  });
};

// setup handling of .disable-if-stale class
(function () {
  function moveAttr(e, fromAttr, toAttr) {
    var toVal = e.getAttribute(toAttr);
    if (!toVal) {
      return;
    }
    var value = e.getAttribute(fromAttr);
    if (!value) {
      return;
    }
    e.removeAttribute(fromAttr);
    e.setAttribute(toAttr, value);
  }
  function processLinks() {
    var enable = !IOCenter.staleness.value;
    $(document.body)[enable ? 'removeClass' : 'addClass']('staleness-active');
    if (enable) {
      $('a.disable-if-stale').each(function (i, e) {
        moveAttr(e, 'disabled-href', 'href');
      });
    } else {
      $('a.disable-if-stale').each(function (i, e) {
        moveAttr(e, 'href', 'disabled-href');
      });
    }
  }
  IOCenter.staleness.subscribeValue(processLinks);
  $(window).bind('template:rendered', processLinks);
})();
