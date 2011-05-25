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
        
        renderTemplate('auto_failover', val), $i('auto_failover_container');
        self.toggle(val.enabled);
    
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
