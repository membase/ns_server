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
  var rawRemoteClustersListCell = model.remoteClustersAllListCell = Cell.compute(function (v) {
    return future.get({url: v.need(remoteClustersListURICell)}, function (list) {
      return _.sortBy(list, function (info) {return info.name});
    });
  });
  rawRemoteClustersListCell.keepValueDuringAsync = true;

  var remoteClustersListCell = model.remoteClustersListCell = Cell.compute(function (v) {
    return _.filter(v.need(rawRemoteClustersListCell), function (info) { return !info.deleted });
  });
  remoteClustersListCell.keepValueDuringAsync = true;

  var createReplicationURICell = model.createReplicationURICell = Cell.computeEager(function (v) {
    return v.need(DAL.cells.currentPoolDetailsCell).controllers.replication.createURI;
  });

  model.refreshReplications = function (softly) {
    if (!softly) {
      remoteClustersListCell.setValue(undefined);
    }
    rawRemoteClustersListCell.invalidate();
    DAL.cells.tasksProgressCell.invalidate();
  }
})();

var ReplicationForm = mkClass({
  initialize: function () {
    var self = this;
    self.dialog = $('#create_replication_dialog');
    self.form = self.dialog.find('form');
    self.onSubmit = $m(self, 'onSubmit');
    self.form.bind('submit', self.onSubmit);
    self.advacedXDCRSettings = $("#js_xdcr_advaced_settings");
    self.advancedSettingsContainer = $("#js_xdcr_advaced_settings_container");

    var xdcrAdvacedSettingsBtn = $("#js_xdcr_advaced_settings_btn");

    self.advacedXDCRSvalidator = setupFormValidation(self.advacedXDCRSettings, "/settings/replications/?just_validate=1", function (status, errors) {
      ReplicationsSection.hideXDCRErrors(self.advacedXDCRSettings);
      if (status == "error") {
        ReplicationsSection.showXDCRErrors(errors, self.advacedXDCRSettings);
      }
    }, function () {
      return serializeForm(self.advacedXDCRSettings);
    });

    self.advacedXDCRSvalidator.pause();

    xdcrAdvacedSettingsBtn.click(function (e) {
      self.advancedSettingsContainer.toggle();
      self.maybeEnabeXDCRFormValidation();
    });

    DAL.cells.bucketsListCell.subscribeValue(function(buckets) {
      if (!buckets) {
        return;
      }
      var rb = $('#replication_from_bucket');
      rb.html('<option value="">select a bucket</option>');
      _.each(buckets.byType.membase, function (bucket) {
        rb.append('<option>' + escapeHTML(bucket.name) + '</option>');
      });
    });
  },
  maybeEnabeXDCRFormValidation: function () {
    var self = this;
    if (self.advancedSettingsContainer.is(":visible")) {
      self.advacedXDCRSvalidator.unpause();
    }
  },
  startCreate: function (callback) {
    var self = this;

    self.advancedSettingsContainer.hide();
    self.advacedXDCRSettings.find("select option[value=xmem]").boolAttr('selected', true);

    self.closeCallback = callback;
    ReplicationsModel.remoteClustersListCell.getValue(function (remoteClusters) {
      self.fillClustersSelect(remoteClusters);
      self.showErrors(false);
      setFormValues(self.form, {
        fromBucket: '',
        toBucket: '',
        toCluster: '',
        replicationType: 'continuous'
      });
      showDialog('create_replication_dialog', {
        position: { my: "center top", at: "center bottom", of: $("#headerNav") },
        onHide: function () {
          self.advacedXDCRSvalidator.pause();
          ReplicationsSection.hideXDCRErrors(self.advacedXDCRSettings);
        }
      });
    });

    $.get("/settings/replications/", function (settings) {
      setFormValues(self.advacedXDCRSettings, settings);
      self.maybeEnabeXDCRFormValidation();
    });
  },
  close: function () {
    hideDialog('create_replication_dialog');
    var callback = this.closeCallback;
    this.closeCallback = null;
    if (callback) {
      callback.apply(this, arguments);
    }
  },
  onSubmit: function (e) {
    e.preventDefault();

    var self = this;
    var URI = ReplicationsModel.createReplicationURICell.value;
    if (!URI) {
      return;
    }
    var spinner = overlayWithSpinner(self.dialog, null, "Creating replication...");
    var formValues = serializeForm(self.form);
    self.showErrors(false);
    jsonPostWithErrors(URI, formValues, function (data, status, errorObject) {
      spinner.remove();
      if (status == 'success') {
        self.close();
      } else {
        self.showErrors(errorObject || data);
      }
    });
  },
  fillClustersSelect: function (remoteClusters) {
    var toClusterSelect = $('#replication_to_cluster');
    toClusterSelect.html("<option value=''>Pick remote cluster</option>");
    _.map(remoteClusters, function (remoteCluster) {
      var option = $("<option></option>");
      option.text(remoteCluster.name);
      option.attr('value', remoteCluster.name);
      toClusterSelect.append(option);
    });
  },
  showErrors: function (errors) {
    var container = $('#create_replication_dialog_errors_container').need(1);
    if (!errors) {
      container.html('');
      return;
    }
    if ((errors instanceof Object) && errors.errors) {
      errors = _.values(errors.errors).sort();
    }
    renderTemplate('create_replication_dialog_errors', errors);
  }
});

// this turns ReplicationForm into lazily initialized singleton
mkClass.turnIntoLazySingleton(ReplicationForm);

ViewHelpers.formatReplicationStatus = function (info) {
  var rawStatus = escapeHTML(info.status);
  var errors = (info.errors || []);
  if (errors.length === 0) {
    return rawStatus;
  }

  var id = _.uniqueId('xdcr_errors');
  var rv = rawStatus + " <a onclick='showXDCRErrors(" + JSON.stringify(id) + ");'>Last " + ViewHelpers.count(errors.length, 'error');
  rv += "</a>"
  rv += "<script type='text/html' id='" + escapeHTML(id) + "'>"
  rv += JSON.stringify(errors)
  rv += "</script>"
  return rv;
}

function showXDCRErrors(id) {
  var text;
  try {
    text = document.getElementById(id).innerHTML;
  } catch (e) {
    console.log("apparently our data element is dead. Ignoring exception: ", e);
    return;
  }
  elements = JSON.parse(text);
  genericDialog({
    buttons: {ok: true},
    header: "XDCR errors",
    textHTML: "<ul>" + _.map(elements, function (anError) {return "<li>" + escapeHTML(anError) + "</li>"}).join('') + "</ul>"
  });
}

function mkReplicationSectionCell(ns, currentXDCRSettingsURI, tasksProgressCell, mode) {
  ns.maybeXDCRTaskCell = Cell.compute(function (v) {
    var progresses = v.need(tasksProgressCell);
    return _.filter(progresses, function (task) {
      return task.type === 'xdcr';
    });
  });
  ns.maybeXDCRTaskCell.equality = _.isEqual;

  // NOTE: code below is a bit complex. That's because we need to
  // fetch both global settings and per-replication settings every
  // time we need combined settings. There is other ways to do it but
  // cell holding cell seems simplest.
  //
  // Ideally given that we only need per-replication settings for
  // editing it in modal dialog, we'd not do it via cells, but that's
  // how this code is done already. And this code is already scheduled
  // for rewrite.
  //
  // Cell-of-cell trick ensures that every recalculation of this cell
  // will re-fetch both endpoints (because "inner cells" will be
  // totally new instances)
  ns.settingsCellCell = Cell.compute(function (v) {
    var uri = v.need(currentXDCRSettingsURI)
    if (!uri) {
      return
    }
    var globalSettingsCell = Cell.compute(function (v) {
      return future.get({url: "/settings/replications"});
    });
    var thisSettingsRawCell = Cell.compute(function () {
      return future.get({url: uri});
    });
    return Cell.compute(function (v) {
      var globalSettings = v(globalSettingsCell);
      var thisSettings = v(thisSettingsRawCell);
      if (!globalSettings || !thisSettings) {
        return;
      }
      return _.extend({}, globalSettings, thisSettings);
    });
  });

  ns.perReplicationSettingsCell = Cell.compute(function (v) {
    return v.need(v.need(ns.settingsCellCell));
  });
  ns.perReplicationSettingsCell.delegateInvalidationMethods(ns.settingsCellCell);

  ns.replicationRowsCell = Cell.compute(function (v) {
    if (v.need(mode) != 'replications') {
      return;
    }

    var replications = v.need(ns.maybeXDCRTaskCell);
    var clusters = v.need(ReplicationsModel.remoteClustersListCell);
    var rawClusters = v.need(ReplicationsModel.remoteClustersAllListCell);

    return _.map(replications, function (replication) {
      var clusterUUID = replication.id.split("/")[0];
      var cluster = _.filter(clusters, function (cluster) {
        return cluster.uuid === clusterUUID;
      })[0];

      var name;
      if (cluster) {
        name = '"' + cluster.name + '"';
      } else {
        cluster = _.filter(rawClusters, function (cluster) {
          return cluster.uuid === clusterUUID;
        })[0];
        if (cluster) {
          // if we found cluster among rawClusters we assume it was
          // deleted
          name = 'at ' + cluster.hostname;
        } else {
          name = '"unknown"';
        }
      }

      var protocolVersion = replication.replicationType === "xmem" ? "2" :
                            replication.replicationType === "capi" ? "1" : BUG();

      return {
        id: replication.id,
        protocol: "Version " + protocolVersion,
        bucket: replication.source,
        to: 'bucket "' + replication.target.split('buckets/')[1] + '" on cluster ' + name,
        status: replication.status == 'running' ? 'Replicating' : 'Starting Up',
        when: replication.continuous ? "on change" : "one time sync",
        errors: replication.errors,
        cancelURI: replication.cancelURI,
        settingsURI: replication.settingsURI
      }
    });
  });
}

var ReplicationsSection = {
  encriptionTextAreaDefaultValue: "Copy paste the Certificate information from Remote Cluster here. You can find the certificate information on Couchbase Admin UI under Settings -> Cluster tab.",
  init: function () {
    renderCellTemplate(ReplicationsModel.remoteClustersListCell, 'cluster_reference_list');

    DAL.cells.isEnterpriseCell.subscribeValue(function (value) {
      if (value == null) {
        return;
      }
      $("#create_cluster_reference_dialog .when-enterprise").toggle(!!value);
    });

    var self = this;
    var perSettingsDialog = $("#js_per_xdcr_settings_dialog");
    var perSettingsForm = $("#js_per_xdcr_settings_dialog form");
    var currentXDCRSettingsURICell = new Cell();
    currentXDCRSettingsURICell.equality = function () {return false};
    $("#demand_encryption_flag-2").bind("change", function () {
      $('#ssh_key_area-2')[$(this).prop('checked') ? 'show' : 'hide']();
    });

    mkReplicationSectionCell(self, currentXDCRSettingsURICell, DAL.cells.tasksProgressCell, DAL.cells.mode);

    self.perReplicationSettingsCell.changedSlot.subscribeOnce(function () {
      setupFormValidation(perSettingsDialog, "/settings/replications/?just_validate=1", function (status, errors) {
        ReplicationsSection.hideXDCRErrors(perSettingsDialog);
        if (status == "error") {
          ReplicationsSection.showXDCRErrors(errors, perSettingsDialog);
        }
      }, function () {
        return serializeForm(perSettingsForm);
      });
    });

    perSettingsForm.submit(function (e) {
      e.preventDefault();
      var spinner = overlayWithSpinner(perSettingsDialog);

      $.ajax({
        type: "POST",
        url: currentXDCRSettingsURICell.value,
        data: serializeForm(perSettingsForm),
        success: function () {
          hideDialog(perSettingsDialog);
        },
        error: function (resp) {
          ReplicationsSection.showXDCRErrors(JSON.parse(resp.responseText), perSettingsDialog);
        },
        complete: function () {
          spinner.remove();
        }
      })
    });

    self.perReplicationSettingsCell.subscribeValue(function (settings) {
      if (!settings) {
        return
      }
      setFormValues(perSettingsDialog, settings);
      showDialog(perSettingsDialog, {
        onHide: function () {
          self.hideXDCRErrors(perSettingsDialog)
        }
      });
    });

    self.replicationRowsCell.subscribeValue(function (rows) {
      if (!rows) {
        return;
      }
      renderTemplate('ongoing_replications_list', rows);
      $("#ongoing_replications_list_container .js_per_xdcr_settings").each(function (i) {
        $(this).click(function () {
          currentXDCRSettingsURICell.setValue(rows[i].settingsURI);
        });
      });
    });

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
    $('#create_replication').click($m(this, 'startCreateReplication'));
  },
  showXDCRErrors: function (errors, perSettingsForm) {
    var i;
    for (i in errors) {
      $("[name=" + i + "]", perSettingsForm).addClass("dynamic_error");
      $(".js_" + i, perSettingsForm).text(errors[i]);
    }
  },
  hideXDCRErrors: function (perSettingsForm) {
    $("input", perSettingsForm).removeClass("dynamic_error");
    $(".js_error", perSettingsForm).text("");
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
      remoteCluster = _.clone(remoteCluster);
      var form = $('#create_cluster_reference_dialog form');
      if (!remoteCluster.certificate) {
        remoteCluster.certificate = ReplicationsSection.encriptionTextAreaDefaultValue;
        $('#demand_encryption_flag-2').prop('checked', false);
        $('#ssh_key_area-2').hide();
      } else {
        $('#ssh_key_area-2').show();
      }
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
    var formValues = $.deparam(serializeForm(form));
    if ($.trim(formValues.certificate) === ReplicationsSection.encriptionTextAreaDefaultValue || !formValues.demandEncryption) {
      formValues.certificate = "";
    }
    if (formValues.hostname && !formValues.hostname.split(":")[1]) {
      formValues.hostname += ":8091";
    }
    jsonPostWithErrors(uri, $.param(formValues), function (data, status, errorObject) {
      spinner.remove();
      if (status == 'success') {
        hideDialog('create_cluster_reference_dialog');
        ReplicationsModel.refreshReplications();
        return;
      }
      renderTemplate('create_cluster_reference_dialog_errors', errorObject ? _.values(errorObject).sort() : data);
    })
  },
  startAddRemoteCluster: function () {
    var form = $('#create_cluster_reference_dialog form');
    form.find('input[type=text], input[type=number], input[type=password], input:not([type])').val('');
    $('#demand_encryption_flag-2').prop('checked', false);
    $('#ssh_key_area-2').val(ReplicationsSection.encriptionTextAreaDefaultValue);
    $('#ssh_key_area-2').hide();
    form.find('input[name=username]').val('Administrator');
    form.find('[name=demandEncryption]').attr('checked', false);
    $('#create_cluster_reference_dialog_errors_container').html('');
    form.bind('submit', onSubmit);
    showDialog('create_cluster_reference_dialog', {
      position: { my: "center top", at: "center bottom", of: $("#headerNav") },
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
        ReplicationsModel.refreshReplications();
      }
    }
  },
  startCreateReplication: function () {
    // TODO: disallow create when no remote clusters are defined
    ReplicationForm.instance().startCreate(function (status) {
      ReplicationsModel.refreshReplications();
    });
  },
  startDeleteReplication: function (cancelURI) {
    ThePage.ensureSection("replications");
    var startedDeleteReplication = ReplicationsSection.startedDeleteReplication = {};

    if (startedDeleteReplication !== ReplicationsSection.startedDeleteReplication) {
      // this guards us against a bunch of rapid delete button
      // presses. Only latest delete operation should pass through this gates
      return;
    }
    askDeleteConfirmation(cancelURI);
    return;

    function askDeleteConfirmation(cancelURI) {
      genericDialog({
        header: "Confirm delete",
        text: "Please, confirm deleting this replication",
        callback: function (e, name, instance) {
          instance.close();
          if (name !== 'ok') {
            return;
          }
          doDelete(cancelURI);
        }
      });
    }

    function doDelete(cancelURI) {
      couchReq('DELETE', cancelURI, {}, function () {
        // this is success callback
        ReplicationsModel.refreshReplications();
      }, function (error, status, handleUnexpected) {
        if (status === 404) {
          ReplicationsModel.refreshReplications();
          return;
        }
        return handleUnexpected();
      });
    }
  },
  onEnter: function() {
    ReplicationsModel.refreshReplications(true);
  }
};

configureActionHashParam("deleteReplication", $m(ReplicationsSection, "startDeleteReplication"));
