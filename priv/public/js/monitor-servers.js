var MonitorServersSection = {
  init: function () {
    ServersSection.serversCell.subscribe(function() {
      renderTemplate('monitor_servers', {rows:ServersSection.active}, $i('monitor_servers_container'));
    });
    DAL.cells.bucketsListCell.subscribeValue(function (list) {
      var empty = (list && list.length === 0);
      $('#monitor_servers table a.node_name')
        [empty ? 'addClass' : 'removeClass']('disabled')
        .bind('click', !empty); // shut off clicking
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
