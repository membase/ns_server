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

function createIndexesSectionCells(ns, modeCell, indexesTableSortByCell, indexesTableSortDescendingCell) {
  ns.isAtIndexesTabCell = Cell.compute(function (v) {
    return v.need(modeCell) === "indexes";
  }).name('isAtIndexesTabCell');
  ns.indexesCell = Cell.compute(function (v) {
    if (!v.need(ns.isAtIndexesTabCell)) {
      return;
    }
    return future.get({url: "/indexStatus"});
  }).name("indexesCell");
  ns.sortedIndexesCell = Cell.compute(function (v) {
    var indexes = v.need(ns.indexesCell);
    var sortBy = v.need(indexesTableSortByCell);
    var sortDescending = v.need(indexesTableSortDescendingCell);
    if (indexes[0] && !indexes[0][sortBy]) {
      sortBy = "hostname";
    }
    var rv = {
      list: indexes,
      descending: sortDescending,
      sortBy: sortBy
    };
    if (!indexes[0]) {
      return rv;
    }
    indexes.sort(mkComparatorByProp(sortBy, naturalSort));
    if (sortDescending === "true") {
      indexes.reverse();
    }
    return rv;
  }).name("sortedIndexesCell");
  ns.sortedIndexesCell.equality = function (a, b) {return false;};
}
var IndexesSection = {
  init: function () {
    var self = IndexesSection;
    var indexesListContainer = $("#js_indexes_list_container");
    var indexesTableSortByCell = new Cell();
    var indexesTableSortDescendingCell = new Cell();
    createIndexesSectionCells(
      IndexesSection,
      DAL.cells.mode,
      indexesTableSortByCell,
      indexesTableSortDescendingCell
    );
    prepareTemplateForCell('js_indexes_list', self.indexesCell);
    var headers
    self.sortedIndexesCell.subscribeValue(function (config) {
      if (!config) {
        return;
      }
      renderTemplate('js_indexes_list', config.list);
      headers = $("[data-sortby]", indexesListContainer);
      headers.click(function () {
        var header = jQuery(this);
        var sortBy = header.data("sortby");
        if (sortBy === indexesTableSortByCell.value) {
          indexesTableSortDescendingCell.setValue(config.descending === "true" ? "false" : "true");
        } else {
          indexesTableSortDescendingCell.setValue("false");
        }
        indexesTableSortByCell.setValue(sortBy);
      });
      indexesListContainer.toggleClass("dynamic_descending", config.descending === "true");
      $("[data-sortby=" + config.sortBy + "]", indexesListContainer).addClass("dynamic_active");
    });
    self.isAtIndexesTabCell.subscribeValue(function (isIndexesTab) {
      if (isIndexesTab) {
        !indexesTableSortByCell.value && indexesTableSortByCell.setValue("hostname");
        !indexesTableSortDescendingCell.value && indexesTableSortDescendingCell.setValue("false");
      }
    })
  },
  onEnter: function () {
  },
  navClick: function () {
  }
};
