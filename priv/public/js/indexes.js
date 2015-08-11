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
  ns.indexURICell = Cell.compute(function (v) {
    return v.need(DAL.cells.currentPoolDetailsCell).indexStatusURI;
  }).name('indexURICell');
  ns.rawIndexesCell = Cell.compute(function (v) {
    if (!v.need(ns.isAtIndexesTabCell)) {
      return;
    }
    var uri = v.need(ns.indexURICell);
    return future.get({url: uri});
  }).name("rawIndexesCell");
  ns.indexesCell = Cell.compute(function (v) {
    return v.need(ns.rawIndexesCell).indexes;
  }).name("indexesCell");
  ns.indexWarningsCell = Cell.compute(function (v) {
    return v.need(ns.rawIndexesCell).warnings;
  }).name("indexWarningsCell");
  ns.sortedIndexesCell = Cell.compute(function (v) {
    var indexes = _.clone(v.need(ns.indexesCell));
    var sortBy = v.need(indexesTableSortByCell);
    var sortDescending = v.need(indexesTableSortDescendingCell);
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
  renderIndexDetails: function (item) {
    return IndexesSection.indexDetails.renderItemDetails(item);
  },
  init: function () {
    var self = IndexesSection;
    var indexesListContainer = $("#js_indexes_list_container");
    var indexesTableSortByCell = new Cell();
    indexesTableSortByCell.setValue("hosts");
    var indexesTableSortDescendingCell = new Cell();
    createIndexesSectionCells(
      IndexesSection,
      DAL.cells.mode,
      indexesTableSortByCell,
      indexesTableSortDescendingCell
    );
    self.indexWarningsCell.subscribeValue(function (warnings) {
      renderTemplate('js_index_warnings', {warnings: warnings});
    });
    prepareTemplateForCell('js_indexes_list', self.indexesCell);
    self.indexDetails = new MultiDrawersWidget({
      hashFragmentParam: 'openedIndexes',
      template: 'index_details',
      elementKey: 'id',
      placeholderCSS: '#js_indexes .details-placeholder',
      actionLink: 'openIndex',
      detailsCellMaker: function (info) {
        return Cell.compute(function (v) {
          return info;
        });
      },
      actionLinkCallback: function () {},
      listCell: Cell.compute(function (v) {
        return v.need(IndexesSection.sortedIndexesCell).list;
      }),
      aroundRendering: function (originalRender, cell, container) {
        originalRender();
        $(container).closest('tr').prev().find('.expander').toggleClass('closed', !cell.interested.value);
      }
    });
    self.sortedIndexesCell.subscribeValue(function (config) {
      if (!config) {
        return;
      }
      renderTemplate('js_indexes_list', config.list);
      activateSortableControls(indexesListContainer, indexesTableSortByCell, indexesTableSortDescendingCell);
    });
    self.isAtIndexesTabCell.subscribeValue(function (isIndexesTab) {
      if (isIndexesTab) {
        !indexesTableSortByCell.value && indexesTableSortByCell.setValue("hosts");
        !indexesTableSortDescendingCell.value && indexesTableSortDescendingCell.setValue("false");
      }
    })
  },
  onEnter: function () {
  },
  navClick: function () {
  }
};
