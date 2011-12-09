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

var LogsSection = {
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

    renderCellTemplate(massagedLogs, 'logs', {
      valueTransformer: function (value) {
        var list = value.list || [];
        return _.clone(list).reverse();
      }
    });

    massagedLogs.subscribeValue(function (massagedLogs) {
      if (massagedLogs === undefined)
        return;
      var stale = massagedLogs.stale;
      $('#logs .staleness-notice')[stale ? 'show' : 'hide']();
    });
  },
  onEnter: function () {
  },
  navClick: function () {
    if (DAL.cells.mode.value == 'log')
      this.logs.recalculate();
  },
  domId: function (sec) {
    return 'logs';
  }
}

var ThePage = {
  sections: {overview: OverviewSection,
             servers: ServersSection,
             analytics: AnalyticsSection,
             buckets: BucketsSection,
             views: ViewsSection,
             replications: ReplicationsSection,
             documents: DocumentsSection,
             edit_doc: EditDocumentSection,
             log: LogsSection,
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
    var self = this;

    _.each(_.uniq(_.values(this.sections)), function (sec) {
      if (sec.init)
        sec.init();
    });

    initAlertsSubscriber();

    DAL.cells.mode.subscribeValue(function (sec) {
      $('.currentNav').removeClass('currentNav');
      $('#switch_' + sec).parent('li').addClass('currentNav');

      var oldSection = self.currentSection;
      var currentSection = self.sections[sec];
      if (!currentSection) {
        return;
      }
      self.currentSectionName = sec;
      self.currentSection = currentSection;

      var secId = sec;
      if (currentSection.domId != null) {
        secId = currentSection.domId(sec);
      }

      if (self.coming[sec] == true && window.location.href.indexOf("FORCE") < 0) {
        secId = 'coming';
      }

      $('#mainPanel > div:not(.notice)').css('display', 'none');
      $('#'+secId).css('display','block');

      _.defer(function () {
        if (oldSection && oldSection.onLeave)
          oldSection.onLeave();
        self.currentSection.onEnter();
        $(window).trigger('sec:' + sec);
      });
    });

    DAL.onReady(function () {
      if (DAL.login) {
        $('.sign-out-link').show();
      }
    });

    watchHashParamChange('sec', 'overview', function (sec) {
      if (sec === 'replications') {
        $($i('switch_replications')).parent().show();
      }
      DAL.switchSection(sec);
    });
    _.defer(function() {
      $(window).trigger('hashchange');
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

var SetupWizard = {
  show: function(page, opt, isContinuation) {
    opt = opt || {};
    page = page || "welcome";

    var pageNames = _.keys(SetupWizard.pages);

    for (var i = 0; i < pageNames.length; i++) {
      if (page == pageNames[i]) {
        var rv;
        if (!isContinuation && SetupWizard.pages[page]) {
          rv = SetupWizard.pages[page]('self', 'init_' + page, opt);
        }
        // if page is in continuation passing style, call it
        // passing continuation and return.  This allows page to do
        // async computation and then resume dialog page switching
        if (rv instanceof Function) {
          $('body, html').css('cursor', 'wait');

          return rv(function () {

            $('body, html').css('cursor', '');
            // we don't pass real continuation, we just call ourselves again
            SetupWizard.show(page, opt, true);
          });
        }
        $(document.body).addClass('init_' + page);
        $('html, body').animate({scrollTop:0},250);
        _.defer(function () {
          var element = $('.focusme:visible').get(0)
          if (!element) {
            return;
          }
          try {element.focus();} catch (e) {}
        });
      }
    }

    if (page == 'done')
      DAL.enableSections();

    // Hiding other pages in a 2nd loop to prevent "flashing" between pages
    for (var i = 0; i < pageNames.length; i++) {
      if (page != pageNames[i]) {
        $(document.body).removeClass('init_' + pageNames[i]);
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
      $('#notice_container').empty();
      alert(notices.join("\n\n"));
    }
  },
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

    var arr = data.hostname.split(':');
    data.clusterMemberHostIp = arr[0];
    data.clusterMemberPort = arr[1] ? arr[1] : '8091';
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
  pages: {
    bucket_dialog: function () {
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
                    SetupWizard.panicAndReload();
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
                                                SetupWizard.show('update_notifications');
                                              }});
        var cleanupBack = dialog.bindWithCleanup($('#step-init-bucket-back'),
                                                 'click',
                                                 function () {
                                                   dialog.cleanup();
                                                   SetupWizard.show('cluster');
                                                 });
        dialog.cleanups.push(cleanupBack);
        dialog.startForm();
      }
    },
    secure: function(node, pagePrefix, opt) {
      var parentName = '#' + pagePrefix + '_dialog';

      $(parentName + ' div.config-bottom button#step-4-finish').unbind('click').click(function (e) {
        e.preventDefault();
        $('#init_secure_form').submit();
      });
      $(parentName + ' div.config-bottom button#step-4-back').unbind('click').click(function (e) {
        e.preventDefault();
        SetupWizard.show("update_notifications");
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
        var vpw = $($i('secure-password-verify')).val();
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
            SetupWizard.show('done');

            if (user != null && user != "") {
              $('.sign-out-link').show();
            }

            dialog.close();
          });
        });
      });
    },
    welcome: function(node, pagePrefix, opt) {
      $('#init_welcome_dialog input.next').click(function (e) {
        e.preventDefault();

        SetupWizard.show("cluster");
      });
    },

    cluster: function (node, pagePrefix, opt) {
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
      // be at one point. SetupWizard.show() will call us immediately
      // passing us it's continuation. This is partial continuation to
      // be more precise
      return function (continueShowDialog) {
        dialog.find('.quota_error_message').hide();

        $.ajax({type:'GET', url:'/nodes/self', dataType: 'json',
                success: dataCallback, error: dataCallback});

        function dataCallback(data, status) {
          if (status != 'success') {
            return SetupWizard.panicAndReload();
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

          var dbPath;
          var dbTotal;

          var ixPath;
          var ixTotal;

          dbPath = dialog.find('[name=db_path]');
          ixPath = dialog.find('[name=index_path]');

          dbTotal = dialog.find('.total-db-size');
          ixTotal = dialog.find('.total-index-size');

          function updateTotal(node, total) {
            node.text(escapeHTML(total) + ' GB');
          }

          dbPath.val(escapeHTML(firstResource.path));
          ixPath.val(escapeHTML(firstResource.path));

          updateTotal(dbTotal, diskTotalGigs);
          updateTotal(ixTotal, diskTotalGigs);

          var hddResources = data.availableStorage.hdd;
          var mountPoints = new MountPoints(data, _.pluck(hddResources, 'path'));

          var prevPathValues = [];

          function maybeUpdateTotal(pathNode, totalNode) {
            var pathValue = pathNode.val();

            if (pathValue == prevPathValues[pathNode]) {
              return;
            }

            prevPathValues[pathNode] = pathValue;
            if (pathValue == "") {
              updateTotal(totalNode, 0);
              return;
            }

            var rv = mountPoints.lookup(pathValue);
            var pathResource = ((rv != null) && hddResources[rv]);

            if (!pathResource) {
              pathResource = {path:"/", sizeKBytes: 0, usagePercent: 0};
            }

            var totalGigs =
              Math.floor(pathResource.sizeKBytes *
                         (100 - pathResource.usagePercent) / 100 / Math.Mi);
            updateTotal(totalNode, totalGigs);
          }

          resourcesObserver = dialog.observePotentialChanges(
            function () {
              maybeUpdateTotal(dbPath, dbTotal);
              maybeUpdateTotal(ixPath, ixTotal);
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

        var dbPath = dialog.find('[name=db_path]').val() || "";
        var ixPath = dialog.find('[name=index_path]').val() || "";

        var m = dialog.find('[name=dynamic-ram-quota]').val() || "";
        if (m == "") {
          m = "none";
        }

        var pathErrorsContainer = dialog.find('.init_cluster_dialog_errors_container');
        var memoryErrorsContainer = $('#init_cluster_dialog_memory_errors_container');
        pathErrorsContainer.hide();
        memoryErrorsContainer.hide();

        postWithValidationErrors('/nodes/' + node + '/controller/settings',
                                 $.param({path: dbPath,
                                          index_path: ixPath}),
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
            SetupWizard.doClusterJoin();
        }

        function handleDiskStatus(data, status) {
          var ok = (status == 'success')
          if (!ok) {
            renderTemplate('join_cluster_dialog_errors', data, pathErrorsContainer[0]);
            pathErrorsContainer.show();
          }
          return ok;
        }

        function memPost(data, status) {
          var ok = handleDiskStatus.apply(null, diskArguments);

          if (status == 'success') {
            if (ok) {
              BucketsSection.refreshBuckets();
              SetupWizard.show("bucket_dialog");
              onLeave();
            }
          } else {
            memoryErrorsContainer.text(data.join(' and '));
            memoryErrorsContainer.show();
          }
        }
      }
    },
    update_notifications: function(node, pagePrefix, opt) {
      var dialog = $('#init_update_notifications_dialog');
      var form = dialog.find('form');
      dialog.find('a.more_info').click(function(e) {
        e.preventDefault();
        dialog.find('p.more_info').slideToggle();
      });
      dialog.find('button.back').click(function (e) {
        e.preventDefault();
        onLeave();
        SetupWizard.show("bucket_dialog");
      });
      // Go to next page. Send off email address if given and apply settings
      dialog.find('button.next').click(function (e) {
        e.preventDefault();
        form.submit();
      });
      _.defer(function () {
        try {
          $('#init-join-community-email').need(1)[0].focus();
        } catch (e) {
        };
      });
      form.bind('submit', function (e) {
        e.preventDefault();
        var email = $.trim($('#init-join-community-email').val());
        if (email !== '') {
          // Send email address. We don't care if notifications were enabled
          // or not.
          $.ajax({
            url: UpdatesNotificationsSection.remote.email,
            dataType: 'jsonp',
            data: {email: email,
                   firstname: $.trim($('#init-join-community-firstname').val()),
                   lastname: $.trim($('#init-join-community-lastname').val()),
                   version: DAL.version || "unknown"},
            success: function () {},
            error: function () {}
          });
        }

        var sendStatus = $('#init-notifications-updates-enabled').is(':checked');
        postWithValidationErrors(
          '/settings/stats',
          $.param({sendStats: sendStatus}),
          function (errors, status) {
            if (status != 'success') {
              return reloadApp(function (reloader) {
                alert('Failed to set update notifications settings. Check your network connection');
                reloader();
              });
            }
            onLeave();
            SetupWizard.show("secure");
          }
        );
      });

      // cleans up all event handles
      function onLeave() {
        dialog.find('a.more_info, button.back, button.next').unbind();
        form.unbind();
      }
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
      $('#about_versions').text("Version: " + DAL.prettyVersion(components['ns_server']));
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

    var buckets = DAL.cells.bucketsListCell.value;
    if (buckets !== undefined) {
      var bucketsCount = buckets.length;
      if (bucketsCount >= 100)
        bucketsCount = 99;

      var memcachedBucketsCount = buckets.byType.memcached.length;
      var membaseBucketsCount = buckets.byType.membase.length;

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
      $($i('cluster_state_id')).text(magicString.join('-'));
    } else {
      $($i('cluster_state_id')).html('Please login to view your ' +
          'Cluster State ID.');
    }
  }
  updateVersion();
  showDialog('about_server_dialog',
      {title: $('#about_server_dialog .config-top').hide().html()});
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
  $('.tooltip_msg', this).stop(true, true).fadeIn();
}).live('mouseleave', function (e) {
  $('.tooltip_msg', this).stop(true, true).fadeOut();
})
.delegate('.tooltip_msg', 'mouseenter', function (e) {
  $(this).stop(true, true).fadeIn(0);
});

configureActionHashParam('visitSec', function (sec) {
  ThePage.gotoSection(sec);
});

$(function () {
  var container = $('.io-error-notice');
  var timeoutId;
  function renderStatus() {
    if (timeoutId != null) {
      clearTimeout(timeoutId);
      timeoutId = null;
    }

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
