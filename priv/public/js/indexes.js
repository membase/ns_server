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

function createIndexesSectionCells(ns, modeCell, tasksProgressCell) {
  ns.isAtIndexesTabCell = Cell.compute(function (v) {
    return v.need(modeCell) === "indexes";
  }).name('isAtIndexesTabCell');
  ns.indexesCell = Cell.compute(function (v) {
    if (!v.need(ns.isAtIndexesTabCell)) {
      return;
    }
    return future.get({url: "/indexStatus"});
  });
}
var IndexesSection = {
  init: function () {
    var self = IndexesSection;
    createIndexesSectionCells(IndexesSection, DAL.cells.mode, DAL.cells.tasksProgressCell);
    prepareTemplateForCell('js_indexes_list', self.indexesCell);
    self.indexesCell.subscribeValue(function (list) {
      if (!list) {
        return;
      }
      renderTemplate('js_indexes_list', list);
    });
  },
  onEnter: function () {
  },
  navClick: function () {
  }
};
