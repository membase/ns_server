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
  processSave: function(self, continuation) {
    var dialog = genericDialog({
      header: 'Saving...',
      text: 'Saving settings.  Please wait a bit.',
      buttons: {ok: false, cancel: false}});

    var form = $(self);

    var postData = serializeForm(form);

    form.find('.warn li').remove();

    postWithValidationErrors($(self).attr('action'), postData, function (data, status) {
      if (status != 'success') {
        var ul = form.find('.warn ul');
        _.each(data, function (error) {
          var li = $('<li></li>');
          li.text(error);
          ul.prepend(li);
        });
        $('html, body').animate({scrollTop: ul.offset().top-100}, 250);
        return dialog.close();
      }

      continuation = continuation || function () {
        reloadApp(function (reload) {
          if (data && data.newBaseUri) {
            var uri = data.newBaseUri;
            if (uri.charAt(uri.length-1) == '/')
              uri = uri.slice(0, -1);
            uri += document.location.pathname;
          }
          _.delay(_.bind(reload, null, uri), 1000);
        });
      }

      continuation(dialog);
    });
  },
  init: function () {
    this.tabs = new TabsCell('settingsTabs',
                             '#settings .tabs',
                             '#settings .panes > div',
                             ['update_notifications', 'auto_failover',
                              'email_alerts']);
    
    UpdatesNotificationsSection.init();
    AutoFailoverSection.init();
    EmailAlertsSection.init();
  },
  onEnter: function () {
    AutoFailoverSection.refresh();
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  },
  onLeave: function () {
  }
};

var UpdatesNotificationsSection = {
  init: function () {
    var self = this;

    // All the infos that are needed to send out the statistics
    var statsInfo = Cell.compute(function (v) {
      return {
        pool: v.need(DAL.cells.currentPoolDetailsCell),
        buckets: v.need(DAL.cells.bucketsListCell)
      };
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

    phEnabled.subscribeValue(function(val) {
      if (val!==undefined) {
        // newVersion has 3 states, either:
        //  - string => new version available
        //  - false => no new version available
        //  - undefined => some error occured, no information available
        var newVersion = undefined;
        // Sending off stats is enabled...
        if (val.sendStats) {
          var errorFun = function(arg1, arg2, arg3) {
            self.renderTemplate(val.sendStats, undefined);
          };

          statsInfo.getValue(function(s) {
            // JSONP requests don't support error callbacks in
            // jQuery 1.4, thus we need to hack around it
            var sendStatsSuccess = false;

            var numMembase = 0;
            for (var i in s.buckets) {
              if (s.buckets[i].bucketType == "membase")
                numMembase++;
            }
            var nodeStats = {
              os: [],
              uptime: []
            };
            for(i in s.pool.nodes) {
              nodeStats.os.push(s.pool.nodes[i].os);
              nodeStats.uptime.push(s.pool.nodes[i].uptime);
            }
            var stats = {
              version: DAL.version,
              componentsVersion: DAL.componentsVersion,
              uuid: DAL.uuid,
              numNodes: s.pool.nodes.length,
              ram: {
                total: s.pool.storageTotals.ram.total,
                quotaTotal: s.pool.storageTotals.ram.quotaTotal,
                quotaUsed: s.pool.storageTotals.ram.quotaUsed
              },
              buckets: {
                total: s.buckets.length,
                membase: numMembase,
                memcached: s.buckets.length - numMembase
              },
              nodes: nodeStats,
              browser: navigator.userAgent
            };
            // This is the request that actually sends the data

            $.ajax({
              url: self.remote.stats,
              dataType: 'jsonp',
              data: {stats: JSON.stringify(stats)},
              // jQuery 1.4 doesn't respond with error, 1.5 should.
              ///error: function() {
              //    self.renderTemplate(true, undefined);
              //},
              timeout: 5000,
              success: function (data) {
                sendStatsSuccess = true;
                self.renderTemplate(true, data);
              }
            });
            // manual error callback
            setTimeout(function() {
              if (!sendStatsSuccess) {
                self.renderTemplate(true, undefined);
              }
            }, 5100);
          });

        } else {
          self.renderTemplate(false, undefined);
        }
      }
    });

    $('#notifications_container').delegate('a.more_info', 'click', function(e) {
      e.preventDefault();
      $('#notifications_container p.more_info').slideToggle();
    });

    $('#notifications_container').delegate('.save_button', 'click', function() {
      var sendStatus = $('#notification-updates').is(':checked');
      postWithValidationErrors('/settings/stats',
                               $.param({sendStats: sendStatus}),
                               function() {
          phEnabled.recalculate();
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
    renderTemplate('leftNav_settings',
                   {enabled: sendStats, newVersion: newVersion},
                   $i('leftNav_settings_container'));
    renderTemplate('notifications',
                   $.extend(data, {enabled: sendStats, version: DAL.version}),
                   $i('notifications_container'));
  },
  remote: {
    stats: 'http://vmische.appspot.com/stats',
    email: 'http://vmische.appspot.com/email'
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

var AutoFailoverSection = {
  init: function () {
    var self = this;
    this.autoFailoverEnabled = Cell.compute(function(v) {
      return future.get({url: "/settings/autoFailover"});
    });
    var autoFailoverEnabled = this.autoFailoverEnabled;

    autoFailoverEnabled.subscribeValue(function(val) {
      if (val!==undefined) {
        console.log('auto-failover:', val);

        renderTemplate('auto_failover', val, $i('auto_failover_container'));
        self.toggle(val.enabled);
        var afc = $('#auto_failover_count_container');
        afc.find('.count').text(val.count);
        afc.find('.maxNodes').text(val.maxNodes);
        afc[val.enabled && val.count/val.maxNodes > 0.5 ? 'show' : 'hide']()
        afc[val.count/val.maxNodes > 0.5 && val.count/val.maxNodes < 0.7 ? 'addClass' : 'removeClass']('notify');

        $('#auto_failover_enabled').change(function() {
          self.toggle($(this).is(':checked'));
        });
      }
    });
    $('#auto_failover_container').delegate('.save_button', 'click', function(){
      var enabled = $('#auto_failover_enabled').is(':checked');
      var age = $('#auto_failover_age').val();
      var maxNodes = $('#auto_failover_max_nodes').val();
      postWithValidationErrors('/settings/autoFailover',
                               $.param({enabled: enabled, age: age,
                                        maxNodes: maxNodes}),
                               function() {
          autoFailoverEnabled.recalculate();
      });
    });
    // reset button
    $('#auto_failover_count_container').delegate('#auto_failover_count_reset',
                                                 'click', function() {
      postWithValidationErrors('/settings/autoFailover/resetCount', {},
                               function() {
          autoFailoverEnabled.recalculate();
      });
    });
  },
  refresh: function() {
    this.autoFailoverEnabled.recalculate();
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
    this.refresh();
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
    this.emailAlertsEnabled = Cell.compute(function(v) {
      return future.get({url: "/settings/alerts"});
    });
    var emailAlertsEnabled = this.emailAlertsEnabled;

    emailAlertsEnabled.subscribeValue(function(val) {
      if (val!==undefined) {
        console.log('email-alerts:', val);

        val.recipients = val.recipients.join('\n');
        val.alerts = [{
          label: 'Node was auto-failovered',
          enabled: $.inArray('auto_failover_node', val.alerts)!==-1,
          value: 'auto_failover_node'
        },{
          label: 'Maximum number of auto-failovered nodes was reached',
          enabled: $.inArray('auto_failover_maximum_reached',
                             val.alerts)!==-1,
          value: 'auto_failover_maximum_reached'
        }];

        renderTemplate('email_alerts', val, $i('email_alerts_container'));
        self.toggle(val.enabled);

        $('#email_alerts_enabled').change(function() {
          self.toggle($(this).is(':checked'));
        });
      }
    });

    $('#test_email').live('click', function() {
      var testButton = $(this).text('Sending...').addClass('disabled');
      $.post('/settings/alerts/testEmail', function(data, status) {
        if (status === 'success') {
          testButton.text('Sent!').css('font-weight', 'bold');
          // Increase compatibility with unnamed functions
          window.setTimeout(function() {
            testButton.text('Test Mail').css('font-weight', 'normal').removeClass('disabled');
          }, 1000);
        }
      });
    });

    $('#email_alerts_container').delegate('.save_button', 'click', function() {
      var alerts = $('#email_alerts_alerts input[type=checkbox]:checked')
        .map(function() {
          return this.value;
        }).get();
      var recipients = $('#email_alerts_recipients')
        .val().replace(/\s+/g, ',');
      console.log(recipients);
      var params = {
        enabled: $('#email_alerts_enabled').is(':checked'),
        recipients: recipients,
        sender: $('#email_alerts_sender').val(),
        emailUser: $('#email_alerts_user').val(),
        emailPass: $('#email_alerts_pass').val(),
        emailHost: $('#email_alerts_host').val(),
        emailPrt: $('#email_alerts_port').val(),
        emailEncrypt: $('#email_alerts_encrypt').is(':checked'),
        alerts: alerts.join(',')
      };
      var maxNodes = $('#auto_failover_max_nodes').val();
      postWithValidationErrors('/settings/alerts', $.param(params),
                               function() {
          emailAlertsEnabled.recalculate();
      });
    });
  },
  refreshEmailAlerts: function() {
    this.emailAlertsEnabled.recalculate();
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
    this.refreshEmailAlerts();
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  },
  onLeave: function () {
  }
};
