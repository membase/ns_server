/**
   Copyright 2015 Couchbase, Inc.

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

function createIndexesSectionCells(ns, modeCell, modeTabsCell, tasksProgressCell) {
  ns.isAtIndexesTabCell = Cell.compute(function (v) {
    return v.need(modeCell) === "indexes" && v.need(modeTabsCell) === "indexes";
  }).name('isAtIndexesTabCell');
  ns.isAtNodesTabCell = Cell.compute(function (v) {
    return v.need(modeCell) === "indexes" && v.need(modeTabsCell) === "nodes";
  }).name('isAtNodesTabCell');
  ns.indexesCell = Cell.compute(function (v) {
    if (!v.need(ns.isAtIndexesTabCell)) {
      return;
    }
    return future.get({url: "/indexStatus"});
  });
  ns.indexNodesCell = Cell.compute(function (v) {
    if (!v.need(ns.isAtNodesTabCell)) {
      return;
    }
    return future.get({url: "/indexStatus"}, valueTransformer);
    function valueTransformer(statusRows) {
      var knownHosts = {};
      _.each(statusRows, function (is) {
        knownHosts[is.hostname] = 1;
      });
      var hostnames = _.keys(knownHosts).sort(naturalSort);
      return _.map(hostnames, function (h) {
        return {hostname: h,
                currentQuota: 'TODO',
                pendingQuota: 'TODO'};
      });
    }
  });
}
var IndexesSection = {
  init: function () {
    var self = IndexesSection;
    self.modeTabsCell = new TabsCell("indexesTab",
                                 "#js_indexes .tabs.switcher",
                                 "#js_indexes .panes > div",
                                 ["indexes", "nodes"]);
    createIndexesSectionCells(IndexesSection, DAL.cells.mode, self.modeTabsCell, DAL.cells.tasksProgressCell);
    prepareTemplateForCell('js_indexes_list', self.indexesCell);
    prepareTemplateForCell('js_index_nodes_list', self.indexNodesCell);
    self.indexesCell.subscribeValue(function (list) {
      if (!list) {
        return;
      }
      renderTemplate('js_indexes_list', list);
    });
    self.indexNodesCell.subscribeValue(function (list) {
      if (!list) {
        return;
      }
      renderTemplate('js_index_nodes_list', list);
    });
  },
  onEnter: function () {
  },
  navClick: function () {
  }
};
