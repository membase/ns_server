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
var ReplicationsModel = {};

(function () {
  var model = ReplicationsModel;
  var remoteClustersListURICell = model.remoteClustersListURICell = Cell.compute(function (v) {
    if (v.need(DAL.cells.mode) != 'replications')
      return;
    return v.need(DAL.cells.currentPoolDetailsCell).remoteClusters.uri;
  });
  var remoteClustersListCell = model.remoteClustersListCell = Cell.compute(function (v) {
    return future.get({url: v.need(remoteClustersListURICell)}, function (list) {
      return _.sortBy(list, function (info) {return info.name});
    });
  });
})();

var ReplicationsSection = {
  init: function () {
    renderCellTemplate(ReplicationsModel.remoteClustersListCell, 'cluster_reference_list');
    renderTemplate('ongoing_replications_list',
        {rows:[{bucket:"default", to:"london", status: "Completed",
          when: "on change",
          lastRun: 1315400994331}]});
    renderTemplate('past_replications_list',
        {rows:[{bucket:"default", to:"bangalore", status: "Failed",
          when: "one time sync",
          lastRun: 1315486775341}]});

    $('#create_cluster_reference').click($m(this, 'startAddRemoteCluster'));
    $('#cluster_reference_list_container').delegate('.list_button.edit-button', 'click', function() {
      var name = $(this).closest('tr').attr('data-name');
      if (!name) {
        return;
      }
      ReplicationsSection.startEditRemoteCluster(name);
    }).delegate('.list_button.delete-button', 'click', function() {
      var name = $(this).closest('tr').attr('data-name');
      if (!name) {
        return;
      }
      ReplicationsSection.startDeleteRemoteCluster(name);
    });
    $('#create_replication, #ongoing_replications_list_container .list_button').click(function() {
      showDialog('create_replication_dialog');
    });
    $('#create_replication_dialog .save_button').click(function() {
      overlayWithSpinner($('#create_replication_dialog'), null, 'Verifying...');
    });
  },
  getRemoteCluster: function (name, body) {
    var self = this;
    var generation = {};
    self.getRemoteClusterGeneration = generation;
    ReplicationsModel.remoteClustersListCell.getValue(function (remoteClustersList) {
      if (generation !== self.getRemoteClusterGeneration) {
        return;
      }
      var remoteCluster = _.detect(remoteClustersList, function (candidate) {
        return (candidate.name === name)
      });
      body.call(self, remoteCluster);
    });
  },
  startEditRemoteCluster: function (name) {
    this.getRemoteCluster(name, function (remoteCluster) {
      if (!remoteCluster) {
        return;
      }
      editRemoteCluster(remoteCluster);
    });
    return;

    function editRemoteCluster(remoteCluster) {
      var form = $('#create_cluster_reference_dialog form');
      setFormValues(form, remoteCluster);
      $('#create_cluster_reference_dialog_errors_container').html('');
      showDialog('create_cluster_reference_dialog', {
        onHide: onHide
      });
      form.bind('submit', onSubmit);

      function onSubmit(e) {
        e.preventDefault();
        ReplicationsSection.submitRemoteCluster(remoteCluster.uri, form);
      }

      function onHide() {
        form.unbind('submit', onSubmit);
      }
    }
  },
  submitRemoteCluster: function (uri, form) {
    var spinner = overlayWithSpinner(form);
    postWithValidationErrors(uri, form, function (data, status) {
      spinner.remove();
      if (status == 'success') {
        hideDialog('create_cluster_reference_dialog');
        ReplicationsModel.remoteClustersListCell.invalidate();
        return;
      }
      renderTemplate('create_cluster_reference_dialog_errors', _.values(data[0]).sort());
    })
  },
  startAddRemoteCluster: function () {
    var form = $('#create_cluster_reference_dialog form');
    form.find('input[type=text], input[type=number], input[type=password], input:not([type])').val('');
    $('#create_cluster_reference_dialog_errors_container').html('');
    form.bind('submit', onSubmit);
    showDialog('create_cluster_reference_dialog', {
      onHide: onHide
    });
    return;

    function onHide() {
      form.unbind('submit', onSubmit);
    }
    var lastGen;
    function onSubmit(e) {
      e.preventDefault();
      var gen = lastGen = {};
      ReplicationsModel.remoteClustersListURICell.getValue(function (url) {
        if (lastGen !== gen) {
          return;
        }
        ReplicationsSection.submitRemoteCluster(url, form);
      });
    }
  },
  startDeleteRemoteCluster: function (name) {
    var remoteCluster;
    this.getRemoteCluster(name, function (_remoteCluster) {
      remoteCluster = _remoteCluster;
      if (!remoteCluster) {
        return;
      }
      genericDialog({text: "Please, confirm deleting remote cluster reference '" + name + "'.",
                     callback: dialogCallback});
    });
    return;

    function dialogCallback(e, name, instance) {
      instance.close();
      if (name != 'ok') {
        return;
      }

      ReplicationsModel.remoteClustersListCell.setValue(undefined);

      $.ajax({
        type: 'DELETE',
        url: remoteCluster.uri,
        success: ajaxCallback,
        errors: ajaxCallback
      });

      function ajaxCallback() {
        ReplicationsModel.remoteClustersListCell.invalidate();
      }
    }
  },
  onEnter: function() {
  }
};