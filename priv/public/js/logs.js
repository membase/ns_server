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

function createLogsSectionCells (ns, modeCell, stalenessCell, tasksProgressCell, logsSectionTabs, serversCell, isROAdminCell) {
  ns.activeTabCell = Cell.needing(modeCell).compute(function (v, mode) {
    return (mode === "log") || undefined;
  }).name('activeTabCell');

  ns.logsRawCell = Cell.needing(ns.activeTabCell).compute(function (v, active) {
    return future.get({url: "/logs"});
  }).name('logsRawCell');

  ns.logsRawCell.keepValueDuringAsync = true;

  ns.massagedLogsCell = Cell.compute(function (v) {
    var logsValue = v(ns.logsRawCell);
    var stale = v.need(stalenessCell);
    if (logsValue === undefined) {
      if (!stale){
        return;
      }
      logsValue = {list: []};
    }
    return _.extend({}, logsValue, {stale: stale});
  }).name('massagedLogsCell');

  ns.isCollectionInfoTabCell = Cell.compute(function (v) {
    return v.need(logsSectionTabs) === "collection_info" &&
           v.need(ns.activeTabCell) && !v.need(isROAdminCell);
  }).name("isClusterTabCell");
  ns.isCollectionInfoTabCell.equality = _.isEqual;

  ns.tasksCollectionInfoCell = Cell.computeEager(function (v) {
    if (!v.need(ns.isCollectionInfoTabCell)) {
      return null;
    }

    var tasks = v.need(tasksProgressCell);
    var task = _.detect(tasks, function (taskInfo) {
      return taskInfo.type === "clusterLogsCollection";
    });
    if (!task) {
      return {
        nodesByStatus: {},
        nodeErrors: [],
        status: 'idle',
        perNode: {}
      }
    }

    // this is cheap deep cloning of task. We're going to add some
    // attributes there and it's best to avoid mutating part of
    // tasksProgressCell value
    task = JSON.parse(JSON.stringify(task));

    var perNodeHash = task.perNode;
    var perNode = [];

    var cancallable = "starting started startingUpload startedUpload".split(" ");

    var nodes = v.need(serversCell).allNodes;

    _.each(perNodeHash, function (ni, nodeName) {
      var node = _.detect(nodes, function (n) {
        return n.otpNode === nodeName;
      });

      ni.nodeName = (node === undefined) ? nodeName.replace(/^.*?@/, '') :
        ViewHelpers.stripPortHTML(node.hostname, nodes);
      perNode.push(ni);
      // possible per-node statuses are:
      //      starting, started, failed, collected,
      //      startingUpload, startedUpload, failedUpload, uploaded

      if (task.status == 'cancelled' && cancallable.indexOf(ni.status) >= 0) {
        ni.status = 'cancelled';
      }
    });

    var nodesByStatus = _.groupBy(perNode, 'status');

    var nodeErrors = _.compact(_.map(perNode, function (ni) {
      if (ni.uploadOutput) {
        return {nodeName: ni.nodeName,
                error: ni.uploadOutput};
      }
    }));

    task.nodesByStatus = nodesByStatus;
    task.nodeErrors = nodeErrors;

    return task;
  }).name("tasksCollectionInfoCell");
  ns.tasksCollectionInfoCell.equality = _.isEqual;

  ns.prepareCollectionInfoNodesCell = Cell.computeEager(function (v) {
    if (!v.need(ns.isCollectionInfoTabCell)) {
      return null;
    }
    var nodes = v.need(serversCell).allNodes;

    return {
      nodes: _(nodes).map(function (node) {
        return {
          nodeClass: node.nodeClass,
          value: node.otpNode,
          isUnhealthy: node.status === 'unhealthy',
          hostname: ViewHelpers.stripPortHTML(node.hostname, nodes)
        };
      })
    }
  }).name("prepareCollectionInfoNodesCell");
  ns.prepareCollectionInfoNodesCell.equality = _.isEqual;
}
var LogsSection = {
  init: function () {
    var collectInfoStartNewView = $("#js_collect_info_start_new_view");
    var selectNodesListCont = $("#js_select_nodes_list_container");
    var uploadToCouchbase = $("#js_upload_to_cb");
    var uploadToHost = $("#js_uploadHost_input");
    var uploadToForm = $("#js_upload_conf");
    var collectForm = $("#js_collect_info_form");
    var collectFromRadios = $("input[name='from']", collectInfoStartNewView);
    var cancelCollectBtn = $("#js_cancel_collect_info");
    var startNewCollectBtn = $("#js_start_new_info");
    var collectInfoWrapper = $("#js_collect_information");
    var collectResultView = $("#js_collect_result_view");
    var collectResultSectionSpinner = $("#js_collect_info_spinner");
    var showResultViewBtn = $("#js_previous_result_btn");
    var cancelConfiramationDialog = $("#js_cancel_collection_confirmation_dialog");
    var saveButton = $(".js_save_button", collectInfoWrapper);

    var collectInfoViewNameCell = new StringHashFragmentCell("collectInfoViewName");

    var allActiveNodeBoxes;
    var allNodeBoxes;
    var overlayCollectInfoStartNewView;
    var self = this;

    collectResultSectionSpinner.show();
    collectResultView.hide();
    collectInfoStartNewView.hide();

    self.tabs = new TabsCell('logsTabs', '#js_logs .tabs', '#js_logs .panes > div', ['logs', 'collection_info']);

    createLogsSectionCells(
      self,
      DAL.cells.mode,
      IOCenter.staleness,
      DAL.cells.tasksProgressCell,
      LogsSection.tabs,
      DAL.cells.serversCell,
      DAL.cells.isROAdminCell
    );

    renderCellTemplate(self.massagedLogsCell, 'logs', {
      valueTransformer: function (value) {
        var list = value.list || [];
        return _.clone(list).reverse();
      }
    });

    cancelCollectBtn.click(function (e) {
      if (cancelCollectBtn.hasClass('dynamic_disabled')) {
        return;
      }
      e.preventDefault();

      showDialog(cancelConfiramationDialog, {
        eventBindings: [['.save_button', 'click', function (e) {
          e.preventDefault();
          hideDialog(cancelConfiramationDialog);

          $.ajax({
            url: '/controller/cancelLogsCollection',
            type: "POST",
            success: function () {
              recalculateTasksUri();
              cancelCollectBtn.addClass('dynamic_disabled');
            },
            error: recalculateTasksUri
          });
        }]]
      });

    });
    startNewCollectBtn.click(function (e) {
      e.preventDefault();
      collectInfoViewNameCell.setValue("startNew");
    });
    showResultViewBtn.click(function (e) {
      e.preventDefault();
      collectInfoViewNameCell.setValue("result");
    });
    collectForm.submit(function (e) {
      e.preventDefault();

      hideErrors();

      var formValues = getCollectFormValues();

      if (formValues["upload"]) {
        if (!formValues["customer"]) {
          showCollectInfoErrors("customer field must be given if upload is selected", "customer");
        }
        if (!formValues["uploadHost"]) {
          showCollectInfoErrors("upload host field must be given if upload is selected", "uploadHost");
        }
        if (!formValues["uploadHost"] || !formValues["customer"]) {
          return;
        }
      }

      saveButton.attr('disabled', true);

      delete formValues["upload"];

      var overlayCollectForm = overlayWithSpinner(collectForm);

      jsonPostWithErrors('/controller/startLogsCollection', $.param(formValues), function (commonError, status, perFieldErrors) {
        overlayCollectForm.remove();
        saveButton.attr('disabled', false);
        if (status === 'success') {
          overlayCollectInfoStartNewView = overlayWithSpinner(collectInfoStartNewView);
          showResultViewBtn.hide();
          self.tasksCollectionInfoCell.changedSlot.subscribeOnce(function () {
            collectInfoViewNameCell.setValue("result");
          });
          recalculateTasksUri();
        } else {
          handleCollectInfoServersError(commonError, perFieldErrors);
        }
      });
    });
    uploadToCouchbase.change(function (e) {
      $('input[type="text"]', uploadToForm).attr('disabled', !$(this).attr('checked'));
    });
    collectFromRadios.change(function (e) {
      if (!allActiveNodeBoxes) {
        return;
      }

      var isAllnodesChecked = $(this).val() == '*';
      if (isAllnodesChecked) {
        allNodeBoxes.attr({checked: true, disabled: true});
      } else {
        allNodeBoxes.attr({checked: false});
        allActiveNodeBoxes.attr({checked: true, disabled: false});
      }
      maybeDisableSaveBtn();
    });

    function getCollectFormValues() {
      var dataArray = collectForm.serializeArray();
      var params = {'selected-nodes': []};
      _.each(dataArray, function (pair) {
        var name = pair.name;
        var value = pair.value;
        if (name === 'js-selected-nodes') {
          params['selected-nodes'].push(value);
        } else {
          params[name] = value;
        }
      });
      if (params['from'] === '*') {
        delete params['from'];
        delete params['selected-nodes'];
        params['nodes'] = '*';
      } else {
        delete params['from'];
        params['nodes'] = params['selected-nodes'].join(',');
        delete params['selected-nodes'];
      }
      _.each(["uploadHost", "customer", "ticket"], function (k) {
        if (params[k] === '') {
          delete params[k];
        }
      });

      return params;
    }

    function handleCollectInfoServersError(commonError, perFieldErrors) {
      _.each((!!commonError.length ? commonError : perFieldErrors), showCollectInfoErrors);
    }
    function showCollectInfoErrors(value, key) {
      key = key || 'generalCollectInfo';
      $("#js_" + key + "_error").text(value).show();
      $("#js_" + key + "_input").addClass("dynamic_input_error");
    }

    function hideErrors() {
      $(".js_error_container", collectInfoStartNewView).hide();
      $(".dynamic_input_error", collectInfoStartNewView).removeClass("dynamic_input_error");
    }

    function recalculateTasksUri() {
      DAL.cells.tasksProgressURI.recalculate();
    }

    function hideResultButtons() {
      startNewCollectBtn.hide();
      cancelCollectBtn.hide();
    }

    function switchCollectionInfoView(isResultView, isCurrentlyRunning, isRunBefore) {
      if (isResultView) {
        collectInfoStartNewView.hide();
        collectResultView.show();
        showResultViewBtn.hide();
        cancelCollectBtn.toggle(isCurrentlyRunning);
        startNewCollectBtn.toggle(!isCurrentlyRunning);
        collectForm[0].reset();
      } else {
        collectInfoStartNewView.show();
        collectResultView.hide();
        hideResultButtons();
        hideErrors();
        showResultViewBtn.toggle(isRunBefore);
      }
    }

    function renderResultView(collectionInfo) {
      renderTemplate('js_collect_progress', collectionInfo);
    }

    function maybeDisableSaveBtn() {
      saveButton.attr('disabled', !jQuery('input:checked', selectNodesListCont).length);
    }

    function renderStartNewView() {
      self.prepareCollectionInfoNodesCell.getValue(function (selectNodesList) {
        renderTemplate('js_select_nodes_list', selectNodesList);
        allActiveNodeBoxes = $('input:not(:disabled)', selectNodesListCont);
        allNodeBoxes = $('input', selectNodesListCont);
        allActiveNodeBoxes.change(maybeDisableSaveBtn);
        collectFromRadios.eq(0).attr('checked', true).trigger('change');
        uploadToCouchbase.attr('checked', false).trigger('change');
        maybeDisableSaveBtn();
      });
    }

    self.isCollectionInfoTabCell.subscribeValue(function (isCollectionInfoTab) {
      if (!isCollectionInfoTab) {
        hideResultButtons();
        showResultViewBtn.hide();
      }
    });

    DAL.cells.isEnterpriseCell.subscribeValue(function (isEnterprise) {
      if (isEnterprise) {
        uploadToHost.val('s3.amazonaws.com/cb-customers');
      }
    });

    Cell.subscribeMultipleValues(function (collectionInfo, tabName) {
      if (!collectionInfo) {
        return;
      }
      var isCurrentlyRunning = collectionInfo.status === 'running';
      var isRunBefore = !!_.keys(collectionInfo.perNode).length;
      var isResultView = tabName === 'result';

      !isCurrentlyRunning && cancelCollectBtn.removeClass('dynamic_disabled');

      if (isCurrentlyRunning) {
        collectInfoViewNameCell.setValue("result");
      } else {
        if (tabName) {
          if (!isRunBefore) {
            collectInfoViewNameCell.setValue("startNew");
          }
        } else {
          var defaultTabName = isRunBefore ? "result": "startNew";
          collectInfoViewNameCell.setValue(defaultTabName);
        }
      }

      switchCollectionInfoView(isResultView, isCurrentlyRunning, isRunBefore);
      collectResultSectionSpinner.hide();

      if (overlayCollectInfoStartNewView) {
        overlayCollectInfoStartNewView.remove();
      }
      if (isResultView) {
        renderResultView(collectionInfo);
      } else {
        renderStartNewView();
      }
    }, self.tasksCollectionInfoCell, collectInfoViewNameCell);

    self.massagedLogsCell.subscribeValue(function (massagedLogs) {
      if (massagedLogs === undefined){
        return;
      }
      var stale = massagedLogs.stale;
      $('#js_logs .staleness-notice')[stale ? 'show' : 'hide']();
    });

    self.logsRawCell.subscribe(function (cell) {
      cell.recalculateAfterDelay(30000);
    });
  },
  onEnter: function () {
  },
  navClick: function () {
    if (DAL.cells.mode.value == 'log'){
      this.logsRawCell.recalculate();
    }
  },
  domId: function (sec) {
    return 'logs';
  }
}
