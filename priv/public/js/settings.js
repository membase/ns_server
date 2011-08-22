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
    UpdatesNotificationsSection.refresh();
    AutoFailoverSection.refresh();
    EmailAlertsSection.refresh();
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  },
  onLeave: function () {
  },
  renderErrors: function(val, rootNode) {
    if (val!==undefined  && DAL.cells.mode.value==='settings') {
      if (val.errors===null) {
        rootNode.find('.error-container.active').empty().removeClass('active');
        rootNode.find('input.invalid').removeClass('invalid');
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
    this.phEnabled = phEnabled;

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
              error: function() {
                 self.renderTemplate(true, undefined);
              },
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
                   $.extend(data, {enabled: sendStats, version: DAL.version}),
                   $i('notifications_container'));
  },
  remote: {
    stats: 'http://vmische.appspot.com/stats',
    email: 'http://vmische.appspot.com/email'
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
          label: 'Node was auto-failovered',
          enabled: $.inArray('auto_failover_node', val.alerts)!==-1,
          value: 'auto_failover_node'
        },{
          label: 'Maximum number of auto-failovered nodes was reached',
          enabled: $.inArray('auto_failover_maximum_reached',
                             val.alerts)!==-1,
          value: 'auto_failover_maximum_reached'
        },{
          label: 'Node wasn\'t auto-failovered as other nodes are down ' +
            'at the same time',
          enabled: $.inArray('auto_failover_other_nodes_down',
                             val.alerts)!==-1,
          value: 'auto_failover_other_nodes_down'
        },{
          label: 'Node wasn\'t auto-failovered as the cluster ' +
            'was too small (less than 3 nodes)',
          enabled: $.inArray('auto_failover_cluster_too_small',
                             val.alerts)!==-1,
          value: 'auto_failover_cluster_too_small'
        }];

        renderTemplate('email_alerts', val, $i('email_alerts_container'));
        self.toggle(val.enabled);

        $('#email_alerts_enabled').change(function() {
          self.toggle($(this).is(':checked'));
        });
      }
    });

    $('#test_email').live('click', function() {
      var testButton = $(this).text('Sending...').attr('disabled', 'disabled');
      var params = $.extend({
        subject: 'Test email from Membase',
        body: 'This email was sent to you to test the email alert email ' +
          'server settings.'
      }, self.getParams());

      postWithValidationErrors('/settings/alerts/testEmail', $.param(params),
                                function (data, status) {
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
