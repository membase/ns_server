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
var ReplicationsSection = {
  init: function () {
    renderTemplate('cluster_reference_list',
        {rows:[{name:"london", ip:"127.0.0.1"}]});
    renderTemplate('ongoing_replications_list',
        {rows:[{bucket:"default", to:"london", status: "Completed",
          when: "on change",
          lastRun: 1315400994331}]});
    renderTemplate('past_replications_list',
        {rows:[{bucket:"default", to:"bangalore", status: "Failed",
          when: "one time sync",
          lastRun: 1315486775341}]});
    
    $('#create_cluster_reference, #cluster_reference_list_container .list_button').click(function() {
      showDialog('create_cluster_reference_dialog');
    });
    $('#create_replication, #ongoing_replications_list_container .list_button').click(function() {
      showDialog('create_replication_dialog');
    });
    $('#create_replication_dialog .save_button').click(function() {
      overlayWithSpinner($('#create_replication_dialog'), null, 'Verifying...');
    });
  },
  onEnter: function() {
  }
};