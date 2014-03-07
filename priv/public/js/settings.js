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
var SettingsSection = {
  init: function () {
    this.tabs = new TabsCell('settingsTabs',
                             '#js_settings .tabs',
                             '#js_settings .panes > div',
                             ['cluster','update_notifications', 'auto_failover',
                              'email_alerts', 'settings_compaction',
                              'settings_sample_buckets', 'account_management']);

    Cell.subscribeMultipleValues(function (isROAdmin, lastCompatMode) {
      if (lastCompatMode === undefined || isROAdmin == undefined) {
        return;
      }

      var rightTab = !isROAdmin ? "account_management" : !lastCompatMode ? "settings_sample_buckets" : "settings_compaction";

      $('#js_settings .tabs > *').removeClass("tab_right");
      $("#" + rightTab).parent().addClass("tab_right");

    }, DAL.cells.isROAdminCell, DAL.cells.runningInCompatMode);

    ClusterSection.init();
    UpdatesNotificationsSection.init();
    AutoFailoverSection.init();
    EmailAlertsSection.init();
    AutoCompactionSection.init();
    SampleBucketSection.init();
    AccountManagementSection.init();
  },
  onEnter: function () {
    SampleBucketSection.refresh();
    UpdatesNotificationsSection.refresh();
    AutoFailoverSection.refresh();
    EmailAlertsSection.refresh();
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  },
  maybeDisableSectionControls: function (section) {
    DAL.cells.isROAdminCell.value && $(section + " :input").prop("disabled", true);
  },
  onLeave: function () {
  },
  renderErrors: function(val, rootNode) {
    if (val!==undefined  && DAL.cells.mode.value==='settings') {
      rootNode.find('.error-container.active').empty().removeClass('active');
      rootNode.find('input.invalid').removeClass('invalid');
      if (val.errors===null) {
        rootNode.find('.save_button').removeAttr('disabled');
      } else {
        // Show error messages on all input fields that contain one
        $.each(val.errors, function(name, message) {
          rootNode.find('.err-'+name).text(message).addClass('active')
            .prev('textarea, input').addClass('invalid');
        });
        // Disable the save button
        rootNode.find('.save_button').attr('disabled', 'disabled');
      }
    }
  }
};

function makeClusterSectionCells(ns, sectionCell, poolDetailsCell, settingTabCell) {
  ns.isClusterTabCell = Cell.compute(function (v) {
    return v.need(settingTabCell) === "cluster" && v.need(sectionCell) === "settings";
  }).name("isClusterTabCell");
  ns.isClusterTabCell.equality = _.isEqual;

  ns.allClusterSectionSettingsCell = Cell.compute(function (v) {
    var currentPool = v.need(poolDetailsCell);
    var isCluster = v.need(ns.isClusterTabCell);
    var ram = currentPool.storageTotals.ram;
    var nNodes = 0;
    $.each(currentPool.nodes, function(n, node) {
      if (node.clusterMembership === "active") {
        nNodes++;
      }
    });
    var ramPerNode = Math.floor(ram.total/nNodes);

    return isCluster ? {
      totalRam: Math.floor(ramPerNode/Math.Mi),
      memoryQuota: Math.floor(ram.quotaTotalPerNode/Math.Mi),
      maxRamMegs: Math.max(Math.floor(ramPerNode/Math.Mi) - 1024, Math.floor(ramPerNode * 4 / (5 * Math.Mi)))
    } : null;
  }).name("allClusterSectionSettingsCell");
  ns.allClusterSectionSettingsCell.equality = _.isEqual;
}

var ClusterSection = {
  init: function () {
    var self = this;
    var poolDetailsCell = DAL.cells.currentPoolDetailsCell;
    var isROAdminCell = DAL.cells.isROAdminCell;
    var internalSettingsUrl = "/internalSettings/visual";

    makeClusterSectionCells(self, DAL.cells.mode, poolDetailsCell, SettingsSection.tabs);

    var container = $("#js_cluster_settings_container");
    var clusterSettingsForm = $("#js_cluster_public_settings_form");
    var totalRamCont = $("#js_cluster_settings_total_ram");
    var maxRamCont = $("#js_ram-max-size");
    var outlineTag = $("#js_outline_tag");
    var certArea = $("#js-about-cert-area");
    var originalTitle = document.title;

    var clusterSettingsFormValidator = setupFormValidation(clusterSettingsForm, internalSettingsUrl + "?just_validate=1",
      function (_status, errors) {
        SettingsSection.renderErrors(errors, clusterSettingsForm);
    }, function () {
      return serializeForm(clusterSettingsForm);
    });

    function enableDisableValidation(enable) {
      clusterSettingsFormValidator[enable ? 'unpause' : 'pause']();
    }

    function setCertificate(certificate) {
      certArea.val(certificate);
    }

    function getCertificate() {
      var overlay = overlayWithSpinner(certArea);
      $.get("/pools/default/certificate", function (data) {
        overlay.remove();
        setCertificate(data);
      });
    }

    window.regenerateCertificate = function regenerateCertificate() {
      var overlay = overlayWithSpinner(certArea);
      $.post("/controller/regenerateCertificate", function (data) {
        overlay.remove();
        setCertificate(data);
      });
    }

    enableDisableValidation(false);

    self.isClusterTabCell.subscribeValue(function (isClusterTab) {
      if (isClusterTab) {
        getCertificate();
      }
    });

    clusterSettingsForm.submit(function (e) {
      e.preventDefault();
      var spinner = overlayWithSpinner(container);
      $.ajax({
        url: internalSettingsUrl,
        type: 'POST',
        data: $.deparam(serializeForm(clusterSettingsForm)),
        success: function () {
          poolDetailsCell.recalculate();
        },
        error: function (jqXhr) {
          SettingsSection.renderErrors(JSON.parse(jqXhr.responseText), clusterSettingsForm);
        },
        complete: function () {
          spinner.remove();
        }
      });

      return false;
    });

    isROAdminCell.subscribeValue(function (isROAdmin) {
      $("input", container).prop("disabled", isROAdmin);
    });

    self.allClusterSectionSettingsCell.subscribeValue(function (settings) {
      if (!settings) {
        return;
      }
      maxRamCont.text(settings.maxRamMegs);
      setFormValues(clusterSettingsForm, settings);
      totalRamCont.text(settings.totalRam);
      enableDisableValidation(!isROAdminCell.value);
    });

    Cell.subscribeMultipleValues(function (isClusterTab, isROAdmin) {
      if (!isClusterTab || isROAdmin) {
        enableDisableValidation(false);
      }
    }, self.isClusterTabCell, isROAdminCell);
  }
};

var UpdatesNotificationsSection = {
  buildPhoneHomeThingy: function (statsInfo) {
    var numMembase = 0;
    for (var i in statsInfo.buckets) {
      if (statsInfo.buckets[i].bucketType == "membase")
        numMembase++;
    }
    var nodeStats = {
      os: [],
      uptime: [],
      istats: []
    };
    for(i in statsInfo.pool.nodes) {
      nodeStats.os.push(statsInfo.pool.nodes[i].os);
      nodeStats.uptime.push(statsInfo.pool.nodes[i].uptime);
      nodeStats.istats.push(statsInfo.pool.nodes[i].interestingStats);
    }
    var stats = {
      version: DAL.version,
      componentsVersion: DAL.componentsVersion,
      uuid: DAL.uuid,
      numNodes: statsInfo.pool.nodes.length,
      ram: {
        total: statsInfo.pool.storageTotals.ram.total,
        quotaTotal: statsInfo.pool.storageTotals.ram.quotaTotal,
        quotaUsed: statsInfo.pool.storageTotals.ram.quotaUsed
      },
      hdd: {
        total: statsInfo.pool.storageTotals.hdd.total,
        quotaTotal: statsInfo.pool.storageTotals.hdd.quotaTotal,
        used: statsInfo.pool.storageTotals.hdd.used,
        usedByData: statsInfo.pool.storageTotals.hdd.usedByData
      },
      buckets: {
        total: statsInfo.buckets.length,
        membase: numMembase,
        memcached: statsInfo.buckets.length - numMembase
      },
      counters: statsInfo.pool.counters,
      nodes: nodeStats,
      browser: navigator.userAgent
    };

    return stats;
  },
  launchMissiles: function (statsInfo, launchID) {
    var self = this;
    var iframe = document.createElement("iframe");
    document.body.appendChild(iframe);
    setTimeout(afterDelay, 10);

    // apparently IE8 needs some delay
    function afterDelay() {
      var iwin = iframe.contentWindow;
      var idoc = iwin.document;
      idoc.body.innerHTML = "<form id=launchpad method=POST><textarea id=sputnik name=stats></textarea></form>";
      var form = idoc.getElementById('launchpad');
      var textarea = idoc.getElementById('sputnik');
      form['action'] = self.remote.stats + '?launchID=' + launchID;
      textarea.innerText = JSON.stringify(self.buildPhoneHomeThingy(statsInfo));
      form.submit();
      setTimeout(function () {
        document.body.removeChild(iframe);
      }, 30000);
    }
  },
  init: function () {
    var self = this;

    // All the infos that are needed to send out the statistics
    var statsInfoCell = Cell.computeEager(function (v) {
      return {
        pool: v.need(DAL.cells.currentPoolDetailsCell),
        buckets: v.need(DAL.cells.bucketsListCell)
      };
    });

    var haveStatsInfo = Cell.computeEager(function (v) {
      return !!v(statsInfoCell);
    });

    var modeDefined = Cell.compute(function (v) {
      v.need(DAL.cells.mode);
      return true;
    });

    var phEnabled = Cell.compute(function(v) {
      // only make the GET request when we are logged in
      v.need(modeDefined);
      return future.get({url: "/settings/stats"});
    });
    self.phEnabled = phEnabled;
    phEnabled.equality = _.isEqual;
    phEnabled.keepValueDuringAsync = true;

    self.hasUpdatesCell = Cell.computeEager(function (v) {
      if (!v(modeDefined)) {
        return;
      }
      var enabled = v.need(phEnabled);
      if (!enabled.sendStats) {
        return false;
      }

      if (!v(haveStatsInfo)) {
        return;
      }

      // note: we could've used keepValueDuringAsync option of cell,
      // but then false returned above when sendStats was off would be
      // kept while we're fetching new versions info.
      //
      // So code below keeps old value iff it's some sensible phone
      // home result rather than false
      var nowValue = this.self.value;
      if (nowValue === false) {
        nowValue = undefined;
      }

      return future(function (valueCallback) {
        statsInfoCell.getValue(function (statsInfo) {
          doSendStuff(statsInfo, function () {
            setTimeout(function () {
              self.hasUpdatesCell.recalculateAfterDelay(3600*1000);
            }, 10);
            return valueCallback.apply(this, arguments);
          });
        });
      }, {nowValue: nowValue});

      function doSendStuff(statsInfo, valueCallback) {
        var launchID = DAL.uuid + '-' + (new Date()).valueOf() + '-' + ((Math.random() * 65536) >> 0);
        self.launchMissiles(statsInfo, launchID);
        var valueDelivered = false;

        $.ajax({
          url: self.remote.stats,
          dataType: 'jsonp',
          data: {launchID: launchID, version: DAL.version},
          error: function() {
            valueDelivered = true;
            valueCallback({failed: true});
          },
          timeout: 15000,
          success: function (data) {
            sendStatsSuccess = true;
            valueCallback(data);
          }
        });
        // manual error callback in case timeout & error thing doesn't
        // work
        setTimeout(function() {
          if (!valueDelivered) {
            valueCallback({failed: true});
          }
        }, 15100);
      }
    });

    Cell.subscribeMultipleValues(function (enabled, phoneHomeResult) {
      if (enabled === undefined || phoneHomeResult === undefined) {
        self.renderTemplate(enabled ? enabled.sendStats : false, undefined);
        prepareAreaUpdate($($i('notifications_container')));
        return;
      }
      if (phoneHomeResult.failed) {
        phoneHomeResult = undefined;
      }
      self.renderTemplate(enabled.sendStats, phoneHomeResult);
    }, phEnabled, self.hasUpdatesCell);

    $('#notifications_container').delegate('a.more_info', 'click', function(e) {
      e.preventDefault();
      $('#notifications_container p.more_info').slideToggle();
    }).delegate('input[type=checkbox]', 'change', function() {
      $('#notifications_container .save_button').removeAttr('disabled');
    }).delegate('.save_button', 'click', function() {
      var button = this;
      var sendStatus = $('#notification-updates').is(':checked');

      $.ajax({
        type: 'POST',
        url: '/settings/stats',
        data: {sendStats: sendStatus},
        success: function() {
          $(button).text('Done!').attr('disabled', 'disabled');
          phEnabled.recalculateAfterDelay(2000);
        },
        error: function() {
          genericDialog({
            buttons: {ok: true},
            header: 'Unable to save settings',
            textHTML: 'An error occured, update notifications settings were' +
              ' not saved.'
          });
        }
      });
    });
  },
  //   - sendStats:boolean Whether update notifications are enabled or not
  //   - data:object Consists of everything that comes back from the
  //     proxy that contains the information about software updates. The
  //     object consists of:
  //     - newVersion:undefined|false|string If it is a string a new version
  //       is available, it is false no now version is available. undefined
  //       means that an error occured while retreiving the information
  //     - links:object An object that contains links to the download and
  //       release notes (keys are "download" and "release").
  //     - info:string Some additional information about the new release
  //       (may contain HTML)
  renderTemplate: function(sendStats, data) {
    var newVersion;
    // data might be undefined.
    if (data) {
      newVersion = data.newVersion;
    } else {
      data = {
        newVersion: undefined
      };
    }
    renderTemplate('nav_settings',
                   {enabled: sendStats, newVersion: newVersion},
                   $i('nav_settings_container'));
    renderTemplate('notifications',
                   $.extend(data, {enabled: sendStats,
                                   version: DAL.version ? DAL.prettyVersion(DAL.version) : ""}),
                   $i('notifications_container'));

    SettingsSection.maybeDisableSectionControls("#notifications_container");
  },
  remote: {
    stats: 'http://ph.couchbase.net/v2',
    email: 'http://ph.couchbase.net/email'
  },
  refresh: function() {
    this.phEnabled.recalculate();
  },
  onEnter: function () {
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  },
  onLeave: function () {
  }
};

var SampleBucketSection = {

  refresh: function() {
    IOCenter.performGet({
      type: 'GET',
      url: '/sampleBuckets',
      dataType: 'json',
      success: function (buckets) {
        var htmlName, tmp, installed = [], available = [];
        _.each(buckets, function(bucket) {
          htmlName = escapeHTML(bucket.name);
          if (bucket.installed) {
            installed.push('<li>' + htmlName + '</li>');
          } else {
            tmp = '<li><input type="checkbox" value="' + htmlName + '" id="sample-' +
              htmlName + '" data-quotaNeeded="'+ bucket.quotaNeeded +
              '" />&nbsp; <label for="sample-' + htmlName + '">' + htmlName +
              '</label></li>';
            available.push(tmp);
          }
        });

        available = (available.length === 0) ?
          '<li>There are no samples available to install.</li>' :
          available.join('');

        installed = (installed.length === 0) ?
          '<li>There are no installed samples.</li>' :
          installed.join('');

        $('#installed_samples').html(installed);
        $('#available_samples').html(available);
        SettingsSection.maybeDisableSectionControls("#sample_buckets_container");
      }
    });
  },
  init: function() {

    var self = this;
    var processing = false;
    var form = $("#sample_buckets_form");
    var button = $("#sample_buckets_settings_btn");
    var quotaWarning = $("#sample_buckets_quota_warning");
    var maximumWarning = $("#sample_buckets_maximum_warning");
    var rebalanceWarning = $("#sample_buckets_rebalance_warning");

    var hasBuckets = false;
    var quotaAvailable = false;
    var numServers = false;
    var numExistingBuckets = false;
    var maxNumBuckets = false;

    var checkedBuckets = function() {
      return _.map($("#sample_buckets_form").find(':checked'), function(obj) {
        return obj;
      });
    };

    var maybeEnableCreateButton = function() {

      if (processing || numServers === false || quotaAvailable === false ||
         numExistingBuckets === false || maxNumBuckets === false) {
        return;
      }

      var checkedBucketsArray = checkedBuckets();
      var storageNeeded = _.reduce(checkedBucketsArray, function(acc, obj) {
        return acc + parseInt($(obj).data('quotaneeded'), 10);
      }, 0) * numServers;
      var isStorageAvailable = storageNeeded <= quotaAvailable;

      if (!isStorageAvailable) {
        $('#sampleQuotaRequired')
          .text(Math.ceil(storageNeeded - quotaAvailable) / 1024 / 1024 / numServers);
        quotaWarning.show();
      } else {
        quotaWarning.hide();
      }

      var maximumBucketsReached = numExistingBuckets + checkedBucketsArray.length > maxNumBuckets;
      if (maximumBucketsReached) {
        $('#maxBucketCount').text(maxNumBuckets);
        maximumWarning.show();
      } else {
        maximumWarning.hide();
      }

      var rebalanceTasks;
      DAL.cells.tasksProgressCell.getValue(function (tasks) {
        rebalanceTasks = _.filter(tasks, function (task) {
          return task.type === 'rebalance' && task.status !== "notRunning";
        });
      });
      rebalanceTasks = rebalanceTasks || [];
      rebalanceWarning[rebalanceTasks.length ? "show" : "hide"]();

      if (hasBuckets && isStorageAvailable && !rebalanceTasks.length && !maximumBucketsReached) {
        button.removeAttr('disabled');
      } else {
        button.attr('disabled', true);
      }
    };

    $('#sample_buckets_form').bind('change', function() {
      hasBuckets = (checkedBuckets().length > 0);
      maybeEnableCreateButton();
    });

    DAL.cells.serversCell.subscribeValue(function (servers) {
      if (servers) {
        numServers = servers.active.length;
        maybeEnableCreateButton();
      }
    });

    DAL.cells.currentPoolDetailsCell.subscribe(function(pool) {
      var storage = pool.value.storageTotals;
      quotaAvailable = storage.ram.quotaTotal - storage.ram.quotaUsed;
      maxNumBuckets = pool.value.maxBucketCount;
      maybeEnableCreateButton();
    });

    DAL.cells.bucketsListCell.subscribe(function(buckets) {
      numExistingBuckets = buckets.value.length;
      maybeEnableCreateButton();
    });

    form.bind('submit', function(e) {

      processing = true;
      button.attr('disabled', true).text('Loading');
      e.preventDefault();

      var buckets = JSON.stringify(_.map(checkedBuckets(), function(obj) {
        return obj.value;
      }));

      jsonPostWithErrors('/sampleBuckets/install', buckets, function (simpleErrors, status, errorObject) {
        if (status === 'success') {
          button.text('Create');
          hasBuckets = processing = false;

          DAL.cells.currentPoolDetailsCell.invalidate();
          DAL.cells.bucketsListCell.invalidate();

          SampleBucketSection.refresh();
        } else {
          var errReason = errorObject && errorObject.reason || simpleErrors.join(' and ');
          button.text('Create');
          hasBuckets = processing = false;

          SampleBucketSection.refresh();
          genericDialog({
            buttons: {ok: true},
            header: 'Error',
            textHTML: errReason
          });
        }
      }, {
        timeout: 140000
      });

    });
  }
};

var AutoFailoverSection = {
  init: function () {
    var self = this;

    var modeDefined = Cell.compute(function (v) {
      v.need(DAL.cells.mode);
      return true;
    });

    this.autoFailoverEnabled = Cell.compute(function(v) {
      // only make the GET request when we are logged in
      v.need(modeDefined);
      return future.get({url: "/settings/autoFailover"});
    });
    var autoFailoverEnabled = this.autoFailoverEnabled;

    autoFailoverEnabled.subscribeValue(function(val) {
      if (val!==undefined) {
        renderTemplate('auto_failover', val, $i('auto_failover_container'));
        self.toggle(val.enabled);
        //$('#auto_failover_container .save_button')
        //  .attr('disabled', 'disabled');
        $('#auto_failover_enabled').change(function() {
          self.toggle($(this).is(':checked'));
        });
        SettingsSection.maybeDisableSectionControls("#auto_failover_container");
      }
    });

    // we need a second cell for the server screen which is updated
    // more frequently (every 20 seconds if the user is currently on the
    // server screen)
    this.autoFailoverEnabledStatus = Cell.compute(function (v) {
      v.need(DAL.cells.mode);
      // Only poll if we are in the server screen
      if (DAL.cells.mode.value==='servers') {
        return future.get({url: "/settings/autoFailover"});
      }
    });
    this.autoFailoverEnabledStatus.subscribeValue(function(val) {
      if (val!==undefined && DAL.cells.mode.value==='servers') {
        // Hard-code the number of maximum nodes for now
        var afc = $('#auto_failover_count_container');
        if (val.count > 0) {
          afc.show();
        } else {
          afc.hide();
        }
      }
    });

    $('#auto_failover_container')
      .delegate('input', 'keyup', self.validate)
      .delegate('input[type=checkbox], input[type=radio]', 'change',
                self.validate);

    $('#auto_failover_container').delegate('.save_button',
                                           'click', function() {
      var button = this;
      var enabled = $('#auto_failover_enabled').is(':checked');
      var timeout = $('#auto_failover_timeout').val();
      $.ajax({
        type: 'POST',
        url: '/settings/autoFailover',
        data: {enabled: enabled, timeout: timeout},
        success: function() {
          $(button).text('Done!').attr('disabled', 'disabled');
          autoFailoverEnabled.recalculateAfterDelay(2000);
        },
        error: function() {
          genericDialog({
            buttons: {ok: true},
            header: 'Unable to save settings',
            textHTML: 'An error occured, auto-failover settings were ' +
              'not saved.'
          });
        }
      });
    });

    // reset button
    $('.auto_failover_count_reset').live('click', function() {
      var button = $('span', this);

      $.ajax({
        type: 'POST',
        url: '/settings/autoFailover/resetCount',
        success: function() {
         var text = button.text();
          button.text('Done!');
          window.setTimeout(function() {
            button.text(text).parents('div').eq(0).hide();
          }, 3000);
        },
        error: function() {
          genericDialog({
            buttons: {ok: true},
            header: 'Unable to reset the auto-failover quota',
            textHTML: 'An error occured, auto-failover quota was not reset.'
          });
        }
      });
    });
  },
  // Refreshes the auto-failover settings interface
  refresh: function() {
    this.autoFailoverEnabled.recalculate();
  },
  // Refreshes the auto-failover status that is shown in the server screen
  refreshStatus: function() {
    this.autoFailoverEnabledStatus.recalculate();
  },
  // Call this function to validate the form
  validate: function() {
    $.ajax({
      url: "/settings/autoFailover?just_validate=1",
      type: 'POST',
      data: {
        enabled: $('#auto_failover_enabled').is(':checked'),
        timeout: $('#auto_failover_timeout').val()
      },
      complete: function(jqXhr) {
        var val = JSON.parse(jqXhr.responseText);
        SettingsSection.renderErrors(val, $('#auto_failover_container'));
      }
    });
  },
  // Enables the input fields
  enable: function() {
    $('#auto_failover_enabled').attr('checked', 'checked');
    $('#auto_failover_container').find('input[type=text]:disabled')
      .removeAttr('disabled');
  },
  // Disabled input fields (read-only)
  disable: function() {
    $('#auto_failover_enabled').removeAttr('checked');
    $('#auto_failover_container').find('input[type=text]')
      .attr('disabled', 'disabled');
  },
  // En-/disables the input fields dependent on the input parameter
  toggle: function(enable) {
    if(enable) {
      this.enable();
    } else {
      this.disable();
    }
  },
  onEnter: function () {
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  },
  onLeave: function () {
  }
};

var EmailAlertsSection = {
  init: function () {
    var self = this;

    var modeDefined = Cell.compute(function (v) {
      v.need(DAL.cells.mode);
      return true;
    });

    this.emailAlertsEnabled = Cell.compute(function(v) {
      v.need(modeDefined);
      return future.get({url: "/settings/alerts"});
    });
    var emailAlertsEnabled = this.emailAlertsEnabled;

    emailAlertsEnabled.subscribeValue(function(val) {
      if (val!==undefined) {
        val.recipients = val.recipients.join('\n');
        val.alerts = [{
          label: 'Node was auto-failed-over',
          enabled: $.inArray('auto_failover_node', val.alerts)!==-1,
          value: 'auto_failover_node'
        },{
          label: 'Maximum number of auto-failed-over nodes was reached',
          enabled: $.inArray('auto_failover_maximum_reached',
                             val.alerts)!==-1,
          value: 'auto_failover_maximum_reached'
        },{
          label: 'Node wasn\'t auto-failed-over as other nodes are down ' +
            'at the same time',
          enabled: $.inArray('auto_failover_other_nodes_down',
                             val.alerts)!==-1,
          value: 'auto_failover_other_nodes_down'
        },{
          label: 'Node wasn\'t auto-failed-over as the cluster ' +
            'was too small (less than 3 nodes)',
          enabled: $.inArray('auto_failover_cluster_too_small',
                             val.alerts)!==-1,
          value: 'auto_failover_cluster_too_small'
        },{
          label: 'Node\'s IP address has changed unexpectedly',
          enabled: $.inArray('ip', val.alerts)!==-1,
          value: 'ip'
        },{
          label: 'Disk space used for persistent storage has reached ' +
            'at least 90% of capacity',
          enabled: $.inArray('disk', val.alerts)!==-1,
          value: 'disk'
        },{
          label: 'Metadata overhead is more than 50%',
          enabled: $.inArray('overhead', val.alerts)!==-1,
          value: 'overhead'
        },{
          label: 'Bucket memory on a node is entirely used for metadata',
          enabled: $.inArray('ep_oom_errors', val.alerts)!==-1,
          value: 'ep_oom_errors'
        },{
          label: 'Writing data to disk for a specific bucket has failed',
          enabled: $.inArray('ep_item_commit_failed', val.alerts)!==-1,
          value: 'ep_item_commit_failed'
        }];

        renderTemplate('email_alerts', val, $i('email_alerts_container'));
        self.toggle(val.enabled);
        SettingsSection.maybeDisableSectionControls("#email_alerts_container");

        $('#email_alerts_enabled').change(function() {
          self.toggle($(this).is(':checked'));
        });
      }
    });

    $('#test_email').live('click', function() {
      var testButton = $(this).text('Sending...').attr('disabled', 'disabled');
      var params = $.extend({
        subject: 'Test email from Couchbase Server',
        body: 'This email was sent to you to test the email alert email ' +
          'server settings.'
      }, self.getParams());

      jsonPostWithErrors('/settings/alerts/testEmail', $.param(params), function (data, status) {
        if (status === 'success') {
          testButton.text('Sent!').css('font-weight', 'bold');
          // Increase compatibility with unnamed functions
          window.setTimeout(function() {
            self.resetEmailButton();
          }, 1000);
        } else if (status === 'error') {
          testButton.text('Error!').css('font-weight', 'bold');
        }
      });
    });

    $('#email_alerts_container')
      .delegate('input', 'keyup', function() {
        self.resetEmailButton();
        self.validate(self.getParams());
      })
      .delegate('textarea, input[type=checkbox], input[type=radio]', 'change',
                function() {
        self.resetEmailButton();
        self.validate(self.getParams());
      });

    $('#email_alerts_container').delegate('.save_button',
                                          'click', function() {
      var button = this;
      var params = self.getParams();

      $.ajax({
        type: 'POST',
        url: '/settings/alerts',
        data: params,
        success: function() {
          $(button).text('Done!').attr('disabled', 'disabled');
          emailAlertsEnabled.recalculateAfterDelay(2000);
        },
        error: function() {
          genericDialog({
            buttons: {ok: true},
            header: 'Unable to save settings',
            textHTML: 'An error occured, alerts settings were not saved.'
          });
        }
      });
    });
  },
  // get the parameters from the input fields
  getParams: function() {
    var alerts = $('#email_alerts_alerts input[type=checkbox]:checked')
      .map(function() {
        return this.value;
      }).get();
    var recipients = $('#email_alerts_recipients')
      .val().replace(/\s+/g, ',');
    return {
      enabled: $('#email_alerts_enabled').is(':checked'),
      recipients: recipients,
      sender: $('#email_alerts_sender').val(),
      emailUser: $('#email_alerts_user').val(),
      emailPass: $('#email_alerts_pass').val(),
      emailHost: $('#email_alerts_host').val(),
      emailPort: $('#email_alerts_port').val(),
      emailEncrypt: $('#email_alerts_encrypt').is(':checked'),
      alerts: alerts.join(',')
    };
  },
  // Resets the email button to the default text and state
  resetEmailButton: function() {
    $('#test_email').text('Test Mail').css('font-weight', 'normal')
      .removeAttr('disabled');
  },
  refresh: function() {
    this.emailAlertsEnabled.recalculate();
  },
  // Call this function to validate the form
  validate: function(data) {
    $.ajax({
      url: "/settings/alerts?just_validate=1",
      type: 'POST',
      data: data,
      complete: function(jqXhr) {
        var val = JSON.parse(jqXhr.responseText);
        SettingsSection.renderErrors(val, $('#email_alerts_container'));
      }
    });
  },
  // Enables the input fields
  enable: function() {
    $('#email_alerts_enabled').attr('checked', 'checked');
    $('#email_alerts_container').find('input:disabled')
      .not('#email_alerts_enabled')
      .removeAttr('disabled');
    $('#email_alerts_container').find('textarea').removeAttr('disabled');
  },
  // Disabled input fields (read-only)
  disable: function() {
    $('#email_alerts_enabled').removeAttr('checked');
    $('#email_alerts_container').find('input')
      .not('#email_alerts_enabled')
      .attr('disabled', 'disabled');
    $('#email_alerts_container').find('textarea')
      .attr('disabled', 'disabled');
  },
  // En-/disables the input fields dependent on the input parameter
  toggle: function(enable) {
    if(enable) {
      this.enable();
    } else {
      this.disable();
    }
  },
  onEnter: function () {
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  },
  onLeave: function () {
  }
};

function accountManagementSectionCells(ns, tabs) {
  var noROAdminMarker = {"valueOf": function () {return ""}};
  var rawROAdminCell = ns.rawROAdminCell = Cell.compute(function (v) {
    if (v.need(tabs) !== 'account_management') {
      return;
    }
    return future.get({url:"/settings/readOnlyAdminName", missingValue: noROAdminMarker});
  }).name("rawROAdminCell");

  ns.isROAdminExistsCell = Cell.compute(function (v) {
    return v.need(rawROAdminCell) !== noROAdminMarker;
  }).name("isROAdminExistsCell");

  ns.roAdminNameCell = Cell.compute(function (v) {
    var value = v.need(rawROAdminCell);
    return String(value);
  }).name("roAdminNameCell");
  ns.roAdminNameCell.delegateInvalidationMethods(rawROAdminCell);

  ns.needSpinnerCell = Cell.compute(function (v) {
    return v.need(tabs) === "account_management" && v(rawROAdminCell) === undefined;
  }).name("needSpinnerCell");
}

var AccountManagementSection = {
  init: function () {
    var self = AccountManagementSection;
    var form = $("#js_account_management_form");
    var fields = {username: false, password: false, verifyPassword: false};
    var credentialsCell = new Cell();
    var errorsCell = new Cell();

    accountManagementSectionCells(self, SettingsSection.tabs);

    self.isROAdminExistsCell.subscribeValue(function (isCreated) {
      $("#js_account_delete")[isCreated ? "show" : "hide"]();
      $("#js_account_management_form")[isCreated ? "hide" : "show"]();
    });

    (function () {
      var spinner;
      var oldValue;
      var timeout;

      var form = $("#js_account_management_form");

      function removeTimeout() {
        clearTimeout(timeout);
        timeout = null;
      }

      function enableSpinner() {
        // NOTE: if we don't do that "trick" with visible we'll do
        // overlayWithSpinner when form is not yet
        // visible. Particularly if page is reloaded when on account
        // management tab
        if (form.is(":visible")) {
          removeTimeout();
          spinner = overlayWithSpinner(form);
        } else {
          if (timeout == null) {
            timeout = setTimeout(function () {
              timeout = null;
              enableSpinner();
            }, 5);
          }
        }
      }

      function disableSpinner() {
        if (spinner) {
          spinner.remove();
          spinner = null;
        }
        removeTimeout();
      }

      self.needSpinnerCell.subscribeValue(function onNeedSpinner(value) {
        if (value === undefined || value === oldValue) {
          return;
        }
        if (value) {
          enableSpinner();
        } else {
          disableSpinner();
        }
        oldValue = value;
      });
    })();

    function showHideErrors(maybeErrors, parent) {
      var key;
      for (key in maybeErrors) {
        $("[name=" + key + "]", parent).toggleClass("error", !!maybeErrors[key]);
        $(".js_error_" + key, parent).text(maybeErrors[key] || "");
      }
    }

    function validateFields(cred, validate) {
      var spinner = overlayWithSpinner(form);

      return $.ajax({
        type: "POST",
        url: "/settings/readOnlyUser" + (validate || ""),
        data: {username: cred.username, password: cred.password},
        success: function () {
          if (validate) {
            errorsCell.setValue(undefined);
          } else {
            form.trigger("reset");
            $("#js_user_created").show();
            $("#js_user_exists").hide();
            self.roAdminNameCell.invalidate();
          }
        },
        error: function (errors) {
          errorsCell.setValue(errors);
        },
        complete: function () {
          spinner.remove();
        }
      });
    }

    SettingsSection.tabs.subscribeValue(function (tab) {
      if (tab != "account_management") {
        return;
      }
      $("#js_user_created").hide();
      $("#js_user_exists").show();
      $("[name='username']", form).focus();
    });

    self.roAdminNameCell.subscribeValue(function (value) {
      $("#js_roadmin_name").text(value || "undefined");
    });

    Cell.subscribeMultipleValues(function (errors, cred) {
      if (!cred) {
        return;
      }
      errors = errors ? JSON.parse(errors.responseText).errors : {};
      var i;
      for (i in cred) {
        if (!cred[i] && !errors[i]) {
          errors[i] = "Empty Field";
        }
      }
      if (cred.password !== cred.verifyPassword) {
        errors.verifyPassword = "Password doesn't match";
      }

      var isValid = $.isEmptyObject(errors);
      showHideErrors(isValid ? fields : _.extend(_.clone(fields), errors), form);

      if (isValid) {
        validateFields(cred);
      }
    }, errorsCell, credentialsCell);

    credentialsCell.subscribeValue(function (cred) {
      if (!cred) {
        return;
      }
      validateFields(cred, "?just_validate=1");
    });

    form.submit(function (e) {
      e.preventDefault();
      credentialsCell.setValue($.deparam(serializeForm($(this))));
    });


    var deleteBtn = $("#js_delete_acc_btn");
    var removeDialog = $("#js_roadmin_remove_dialog");

    deleteBtn.click(function () {
      showDialog(removeDialog, {
        eventBindings: [['.js_delete_button', 'click', function (e) {
          e.preventDefault();
          var spinner = overlayWithSpinner(removeDialog);
          $.ajax({
            type: "DELETE",
            url: "/settings/readOnlyUser",
            success: function () {
              hideDialog(removeDialog);
              self.roAdminNameCell.invalidate();
            },
            error: function (errors, status) {
              if (errors.status == 404) {
                hideDialog(removeDialog);
              } else {
                reloadApp();
              }
            },
            complete: function () {
              spinner.remove();
            }
          });
        }]]
      });
    });

    var resetForm = $("#js_reset_roadmin_form");
    var resetBtn = $("#js_reset_acc_btn");
    var resetDialog = $("#js_roadmin_reset_dialog");

    function cleanResetForm() {
      resetForm.trigger("reset");
      showHideErrors({password: false}, resetForm);
    }

    function maybeRestFields(resetCred) {
      var spinner = overlayWithSpinner(resetDialog);

      return $.ajax({
        type: "PUT",
        url: "/settings/readOnlyUser",
        data: {password: resetCred.password},
        success: function () {
          cleanResetForm();
          hideDialog(resetDialog);
        },
        error: function (errors) {
          switch (errors.status) {
            case 404:
              showHideErrors({password: JSON.parse(errors.responseText)}, resetForm);
            break;
            case 400:
              showHideErrors(JSON.parse(errors.responseText).errors, resetForm);
            break;
            default:
              reloadApp();
          }
        },
        complete: function () {
          spinner.remove();
        }
      });
    }

    resetForm.submit(function (e) {
      e.preventDefault();
      maybeRestFields($.deparam(serializeForm($(this))));
    });
    resetBtn.click(function () {
      showDialog(resetDialog, {
        closeOnEscape: true,
        onHide: cleanResetForm
      });
    });

  }
};

var AutoCompactionSection = {
  getSettingsFuture: function () {
    return future.get({url: '/settings/autoCompaction'});
  },
  init: function () {
    var self = this;

    var allSettingsCell = Cell.compute(function (v) {
      if (v.need(SettingsSection.tabs) != 'settings_compaction') {
        return;
      }
      return self.getSettingsFuture();
    });
    var settingsCell = Cell.needing(allSettingsCell).computeEager(function (v, allSettings) {
      var rv = _.extend({}, allSettings.autoCompactionSettings);
      rv.purgeInterval = allSettings.purgeInterval;
      return rv;
    });
    settingsCell.equality = _.isEqual;
    settingsCell.delegateInvalidationMethods(allSettingsCell);
    self.settingsCell = settingsCell;
    var errorsCell = self.errorsCell = new Cell();
    self.errorsCell.subscribeValue($m(self, 'onValidationResult'));
    self.urisCell = new Cell();
    self.formValidationEnabled = new Cell();
    self.formValidationEnabled.setValue(false);

    var container = self.container = $('#compaction_container');

    self.formValidation = undefined;

    DAL.cells.currentPoolDetailsCell.getValue(function (poolDetails) {
      var value = poolDetails.controllers.setAutoCompaction;
      if (!value) {
        BUG();
      }
      AutoCompactionSection.urisCell.setValue(value)
    });

    var formValidation;

    self.urisCell.getValue(function (uris) {
      var validateURI = uris.validateURI;
      var form = container.find("form");
      formValidation = setupFormValidation(form, validateURI, function (status, errors) {
        errorsCell.setValue(errors);
      }, function() {
        return AutoCompactionSection.serializeCompactionForm(form);
      });
      self.formValidationEnabled.subscribeValue(function (enabled) {
        formValidation[enabled ? 'unpause' : 'pause']();
      });
    });

    (function () {
      var needSpinnerCell = Cell.compute(function (v) {
        if (v.need(SettingsSection.tabs) != 'settings_compaction') {
          return false;
        }
        return !v(settingsCell);
      });
      var spinner;
      needSpinnerCell.subscribeValue(function (val) {
        if (!val) {
          if (spinner) {
            spinner.remove();
            spinner = null;
          }
        } else {
          if (!spinner) {
            spinner = overlayWithSpinner(container);
          }
        }
      });

      container.find('form').bind('submit', function (e) {
        e.preventDefault();
        if (spinner) {
          return;
        }

        self.submit();
      });
    })();

    (function () {
      var tempDisabledInputs;
      var roadminCell = DAL.cells.isROAdminCell;

      function resetAutoCompaction(isROAdmin) {
        self.errorsCell.setValue({});
        self.fillSettingsForm(function () {
          self.formValidationEnabled.setValue(!isROAdmin);
          if (!isROAdmin && tempDisabledInputs) {
            tempDisabledInputs.prop("disabled", false);
            tempDisabledInputs = undefined;
            return;
          }
          if (isROAdmin) {
            tempDisabledInputs = $("#compaction_container :input").filter(":enabled");
            SettingsSection.maybeDisableSectionControls("#compaction_container");
          }
        });
      }

      SettingsSection.tabs.subscribeValue(function (val) {
        if (val !== 'settings_compaction') {
          self.formValidationEnabled.setValue(false);
          return;
        }
        resetAutoCompaction(roadminCell.value);
      });
      roadminCell.subscribeValue(resetAutoCompaction);
    })();
  },
  serializeCompactionForm: function(form) {
    return serializeForm(form, {
      'databaseFragmentationThreshold[size]': MBtoBytes,
      'viewFragmentationThreshold[size]': MBtoBytes,
      'purgeInterval': function purgeInterval(value) {
        var rv = Number(value);
        return rv ? rv : value;
      }
    });
  },
  preProcessCompactionValues: function(values) {
    var fields = [
      "databaseFragmentationThreshold[size]",
      "databaseFragmentationThreshold[percentage]",
      "viewFragmentationThreshold[size]",
      "viewFragmentationThreshold[percentage]",
      "allowedTimePeriod[fromHour]",
      "allowedTimePeriod[fromMinute]",
      "allowedTimePeriod[toHour]",
      "allowedTimePeriod[toMinute]"
    ];
    _.each(fields, function(key) {
      if (values[key] === 'undefined') {
        delete values[key];
      }
      if (values[key] &&
          (key === 'databaseFragmentationThreshold[size]' ||
           key === 'viewFragmentationThreshold[size]')) {
        values[key] = Math.round(values[key] / 1024 / 1024);
      }
      if (isFinite(values[key]) &&
          (key === 'allowedTimePeriod[fromHour]' ||
           key === 'allowedTimePeriod[fromMinute]' ||
           key === 'allowedTimePeriod[toHour]' ||
           key === 'allowedTimePeriod[toMinute]')) {
        // add leading zero where needed
        values[key] = (values[key] + 100).toString().substring(1);
      }
    });
    return values;
  },
  fillSettingsForm: function (whenDone) {
    var self = this;
    var myGeneration = self.fillSettingsGeneration = new Object();
    self.settingsCell.getValue(function (settings) {
      if (myGeneration !== self.fillSettingsGeneration) {
        return;
      }

      settings = _.clone(settings);
      _.each(settings, function (value, k) {
        if (value instanceof Object) {
          _.each(value, function (subVal, subK) {
            settings[k+'['+subK+']'] = subVal;
          });
        }
      });

      if (self.formDestructor) {
        self.formDestructor();
      }
      settings = AutoCompactionSection.preProcessCompactionValues(settings);
      var form = self.container.find("form");
      setFormValues(form, settings);
      self.formDestructor = setAutoCompactionSettingsFields(form, settings);

      if (whenDone) {
        whenDone();
      }
    });
  },
  METADATA_PURGE_INTERVAL_WARNING: "The Metadata purge interval should always be set to a value that is greater than the indexing or XDCR lag. Are you sure you want to change the metadata purge interval?",
  displayMetadataPurgeIntervalWarning: function (onOk) {
    genericDialog({
      buttons: {ok: true, cancel: true},
      text: AutoCompactionSection.METADATA_PURGE_INTERVAL_WARNING,
      callback: function (e, name, instance) {
        instance.close();
        if (name == 'ok') {
          onOk();
        }
      }});
  },
  submit: function () {
    var self = this;
    var dialog;

    var oldPurgeInterval = String(self.settingsCell.value.purgeInterval);

    var data = AutoCompactionSection.serializeCompactionForm(self.container.find("form"));

    var newPurgeInterval = self.container.find("form [name=purgeInterval]").val();
    if (newPurgeInterval != oldPurgeInterval) {
      self.displayMetadataPurgeIntervalWarning(continueSaving);
    } else {
      continueSaving();
    }

    return;

    function continueSaving() {
      dialog = genericDialog({buttons: {},
                              closeOnEscape: false,
                              header: "Saving...",
                              text: "Saving autocompaction settings. Please, wait..."});

      self.urisCell.getValue(function (uris) {
        jsonPostWithErrors(uris.uri, data, onSubmitResult);
        self.formValidationEnabled.setValue(false);
      });
    }

    function onSubmitResult(simpleErrors, status, errorObject) {
      self.settingsCell.setValue(undefined);
      self.settingsCell.invalidate();
      dialog.close();

      if (status == "success") {
        self.errorsCell.setValue({});
        self.fillSettingsForm();
      } else {
        self.errorsCell.setValue(errorObject);
        if (simpleErrors && simpleErrors.length) {
          genericDialog({buttons: {ok: true, cancel: false},
                         header: "Failed To Save Auto-Compaction Settings",
                         text: simpleErrors.join(' and ')});
        }
      }
      self.formValidationEnabled.setValue(true);
    }
  },
  renderError: function (field, error) {
    var fieldClass = field.replace(/\[|\]/g, '-');
    this.container.find('.error-container.err-' + fieldClass).text(error || '')[error ? 'addClass' : 'removeClass']('active');
    this.container.find('[name="' + field + '"]')[error ? 'addClass' : 'removeClass']('invalid');
  },
  onValidationResult: (function () {
    var knownFields = ('name ramQuotaMB replicaNumber proxyPort databaseFragmentationThreshold[percentage] viewFragmentationThreshold[percentage] viewFragmentationThreshold[size] databaseFragmentationThreshold[size] allowedTimePeriod purgeInterval').split(' ');
    _.each(('to from').split(' '), function (p1) {
      _.each(('Hour Minute').split(' '), function (p2) {
        knownFields.push('allowedTimePeriod[' + p1 + p2 + ']');
      });
    });

    return function (result) {
      if (!result) {
        return;
      }
      var self = this;
      var errors = result.errors || {};
      _.each(knownFields, function (name) {
        self.renderError(name, errors[name]);
      });
    };
  })()
};
