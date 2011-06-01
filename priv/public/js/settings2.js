var Settings2Section = {
  init: function () {
    this.tabs = new TabsCell('settingsTabs',
                             '#settings2 .tabs',
                             '#settings2 .panes > div',
                             ['update_notifications', 'auto_failover',
                              'email_alerts']);
    
    UpdatesNotificationsSection.init();
    AutoFailoverSection.init();
    EmailAlertsSection.init();
  },
  onEnter: function () {
    AutoFailoverSection.refreshAutoFailover();
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  },
  onLeave: function () {
  }
};
