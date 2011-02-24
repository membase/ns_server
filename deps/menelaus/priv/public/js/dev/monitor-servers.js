var MonitorServersSection = {
  init: function () {
    ServersSection.serversCell.subscribe(function() {
      renderTemplate('monitor_servers', {rows:ServersSection.allNodes}, $i('monitor_servers_container'));
    });
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