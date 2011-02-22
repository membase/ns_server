function handlePasswordMatch(parent) {
  var passwd = parent.find("[name=password]:not([disabled])").val();
  var passwd2 = parent.find("[name=verifyPassword]:not([disabled])").val();
  var show = (passwd != passwd2);
  parent.find('.dont-match')[show ? 'show' : 'hide']();
  parent.find('[type=submit]').each(function () {
    $(this).boolAttr('disabled', show);
  });
  return !show;
}

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
  // GET of advanced settings returns structure, while POST accepts
  // only plain key-value set. We convert data we get from GET to
  // format of POST requests.
  flattenAdvancedSettings: function (data) {
    var rv = {};
    $.extend(rv, data.ports); // proxyPort & directPort

    var alerts = data.alerts;
    rv['email'] = alerts['email']
    rv['sender'] = alerts['sender']
    rv['email_alerts'] = alerts['sendAlerts'];

    for (var k in alerts.email_server) {
      rv['email_server_' + k] = alerts.email_server[k];
    }

    for (var k in alerts.alerts) {
      rv['alert_' + k] = alerts.alerts[k];
    }

    return rv;
  },
  handleHideShowCheckboxes: function () {
    var alertSet = $('#alert_set');
    var method = (alertSet.get(0).checked) ? 'addClass' : 'removeClass'
    $('#alerts_settings_guts')[method]('block');

    var secureServ = $('#secure_serv');
    var isVisible = (secureServ.get(0).checked);
    method = isVisible ? 'addClass' : 'removeClass';
    $('#server_secure')[method]('block');
    $('#server_secure input:not([type=hidden])').boolAttr('disabled', !isVisible)
  },
  init: function () {
    var self = this;

    $('#alert_set, #secure_serv').click($m(self, 'handleHideShowCheckboxes'));

    self.tabs = new TabsCell("settingsTab",
                             '#settings .tabs',
                             '#settings .panes > div',
                             ['basic', 'advanced']);
    self.webSettings = new Cell(function (mode) {
      if (mode != 'settings')
        return;
      return future.get({url: '/settings/web'});
    }).setSources({mode: DAL.cells.mode});

    self.advancedSettings = new Cell(function (mode) {
      // alerts section depend on this too
      if (mode != 'settings' && mode != 'alerts')
        return;
      return future.get({url: '/settings/advanced'}, $m(self, 'flattenAdvancedSettings'));
    }).setSources({mode: DAL.cells.mode});

    self.webSettingsOverlay = null;
    self.advancedSettingsOverlay = null;

    function bindOverlay(cell, varName, form) {
      function onUndef() {
        self[varName] = overlayWithSpinner(form);
      }
      function onDef() {
        var spinner = self[varName];
        if (spinner) {
          self[varName] = null;
          spinner.remove();
        }
      }
      cell.subscribe(onUndef, {'undefined': true, 'changed': false});
      cell.subscribe(onDef, {'undefined': false, 'changed': true});
    }

    bindOverlay(self.webSettings, 'webSettingsOverlay', '#basic_settings_form');
    bindOverlay(self.advancedSettings, 'advancedSettingsOverlay', '#advanced_settings_form');

    self.webSettings.subscribe($m(this, 'fillBasicForm'));
    self.advancedSettings.subscribe($m(this, 'fillAdvancedForm'));

    var basicSettingsForm = $('#basic_settings_form');
    basicSettingsForm.observePotentialChanges(function () {
      if (basicSettingsForm.find('#secure_serv').is(':checked')) {
        handlePasswordMatch(basicSettingsForm);
      } else {
        basicSettingsForm.find('[type=submit]').boolAttr('disabled', false);
      }
    });

    $('#settings form').submit(function (e) {
      e.preventDefault();
      SetingsSection.processSave(this);
    });
  },
  gotoSetupAlerts: function () {
    var self = this;

    self.tabs.setValue('advanced');

    function switchAlertsOn() {
      if (self.advancedSettings.value && ('email_alerts' in self.advancedSettings.value)) {
        _.defer(function () { // make sure we do it after form is filled
          $('#advanced_settings_form [name=email_alerts]').boolAttr('checked', true);
          self.handleHideShowCheckboxes();
        });
        return
      }

      self.advancedSettings.changedSlot.subscribeOnce(switchAlertsOn);
    }

    switchAlertsOn();
    ThePage.gotoSection('settings');
  },
  gotoSecureServer: function () {
    var self = this;

    self.tabs.setValue('basic');
    ThePage.gotoSection('settings');

    function switchSecureOn() {
      if (self.webSettings.value && ('port' in self.webSettings.value)) {
        _.defer(function () {
          $('#secure_serv').boolAttr('checked', true);
          self.handleHideShowCheckboxes();
          $('#basic_settings_form input[name=username]').get(0).focus();
        });
        return;
      }

      self.webSettings.changedSlot.subscribeOnce(switchSecureOn);
    }
    switchSecureOn();
  },
  fillBasicForm: function () {
    var form = $('#basic_settings_form');
    setFormValues(form, this.webSettings.value);
    form.find('[name=verifyPassword]').val(this.webSettings.value['password']);
    $('#secure_serv').boolAttr('checked', !!(this.webSettings.value['username']));
    this.handleHideShowCheckboxes();
  },
  fillAdvancedForm: function () {
    setFormValues($('#advanced_settings_form'), this.advancedSettings.value);
    this.handleHideShowCheckboxes();
  },
  onEnter: function () {
    // this.advancedSettings.setValue({});
    // this.advancedSettings.recalculate();

    // this.webSettings.setValue({});
    // this.webSettings.recalculate();
  },
  onLeave: function () {
    $('#settings form').each(function () {
      this.reset();
    });
  }
};
