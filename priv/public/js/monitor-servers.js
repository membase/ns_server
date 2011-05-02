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
var MonitorServersSection = {
  init: function () {
    ServersSection.serversCell.subscribeValue(function(servers) {
      if (!servers) {
        return;
      }
      renderTemplate('monitor_servers', {rows:servers.active}, $i('monitor_servers_container'));
    });
    prepareTemplateForCell('monitor_servers', ServersSection.serversCell);
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
