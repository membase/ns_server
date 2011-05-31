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
        },{
          label: 'No auto-failover as too many nodes went down at the ' +
            'same time',
          enabled: $.inArray('auto_failover_too_many_nodes_down',
                             val.alerts)!==-1,
          value: 'auto_failover_too_many_nodes_down'
        }];

        renderTemplate('email_alerts', val, $i('email_alerts_container'));
        self.toggle(val.enabled);
    
        $('#email_alerts_enabled').change(function() {
          self.toggle($(this).is(':checked'));
        });
      }
    });

    $('#email_alerts .save_button').click(function(){
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
