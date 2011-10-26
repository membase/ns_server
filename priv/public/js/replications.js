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
  var remoteClustersListHostPort = model.remoteClustersListHostPort = Cell.compute(function (v) {
    var list = v.need(remoteClustersListCell);
    return _.map(list, function (remoteClusterInfo) {
      var hostname = remoteClusterInfo.hostname;
      var match = /^(.+?)(?::([^:]+))?$/.exec(hostname);
      return [remoteClusterInfo.name, match[1], match[2] || "8091"];
    });
  });

  var createReplicationURICell = model.createReplicationURICell = Cell.computeEager(function (v) {
    return v.need(DAL.cells.currentPoolDetailsCell).controllers.replication.createURI;
  });
  var replicationInfosURICell = model.replicationInfosURICell = Cell.computeEager(function (v) {
    return v.need(DAL.cells.currentPoolDetailsCell).controllers.replication.infosURI;
  });

  var rawReplicationInfos = model.rawReplicationInfos = Cell.computeEager(function (v) {
    if (v.need(DAL.cells.mode) !== 'replications') {
      return;
    }
    return future.get({url: v.need(replicationInfosURICell)});
  });

  var allReplicationInfos = model.allReplicationInfos = Cell.compute(function (v) {
    var name2hostport = v.need(remoteClustersListHostPort);
    return _.map(v.need(rawReplicationInfos).rows, function (r) {
      var info = r.value;
      var fields = info.replication_fields;
      if (!fields) {
        return info;
      }
      var targetURI = fields.target;
      var match1 = /^http:\/\/(.*?)\/(.*)/.exec(targetURI);
      if (!match1) {
        return info;
      }

      var authAndHost = match1[1];
      var match2 = /^(.*@)?(.*?)(?::([^:]+))?$/.exec(authAndHost);
      if (!match2) {
        BUG("!match2");
      }
      var host = match2[2];
      var port = match2[3] || "80";
      var triple = _.detect(name2hostport, function (ct) {
        return ct[1] === host && ct[2] === port;
      });
      if (triple) {
        targetURI = triple[0];
      }
      info = _.clone(info);
      info._id = fields._id;
      info.source = fields.source;
      info.target = targetURI;
      info.continuous = fields.continuous;
      if (triple && fields.targetBucket !== info.source) {
        info.target += ' bucket ' + fields.targetBucket;
      }
      return info;
    });
  });

  function currentReplicationInfoP(info) {
    return (info.have_replicator_doc
            && info._replication_state !== 'cancelled'
            && (info._replication_state !== 'completed' || info.continuous === true));
  }

  model.currentReplicationInfoP = currentReplicationInfoP;

  var currentReplicationInfos = model.currentReplicationInfos = Cell.compute(function (v) {
    return _.select(v.need(allReplicationInfos), currentReplicationInfoP);
  });

  var pastReplicationInfos = model.pastReplicationInfos = Cell.compute(function (v) {
    return _.reject(v.need(allReplicationInfos), currentReplicationInfoP);
  });

  model.refreshReplications = function () {
    remoteClustersListCell.invalidate();
    rawReplicationInfos.invalidate();
  }

  var replicatorDBURIBaseCell = model.replicatorDBURIBaseCell = Cell.computeEager(function (v) {
    return v.need(DAL.cells.currentPoolDetailsCell).controllers.replication.replicatorDBURI + "/";
  });
})();

var ReplicationForm = mkClass({
  initialize: function () {
    this.dialog = $('#create_replication_dialog');
    this.form = this.dialog.find('form');
    this.onSubmit = $m(this, 'onSubmit');
    this.formObserver = $m(this, 'formObserver');
    this.onHide = $m(this, 'onHide');
    this.form.bind('submit', this.onSubmit);
  },
  startCreate: function (callback) {
    var self = this;
    if (self.shown) {
      BUG();
    }
    self.closeCallback = callback;
    self.shown = true;
    ReplicationsModel.remoteClustersListCell.getValue(function (remoteClusters) {
      self.fillClustersSelect(remoteClusters);
      self.showErrors(false);
      setFormValues(self.form, {
        fromBucket: '',
        toBucket: '',
        toCluster: '',
        replicationType: 'continuous'
      });
      self.verifyPassed = null;
      self.startFormObserver();
      showDialog('create_replication_dialog', {
        onHide: self.onHide
      });
    });
  },
  startFormObserver: function () {
    this._formObserver = this.form.observePotentialChanges(this.formObserver);
    this.formObserver(true);
  },
  close: function () {
    if (!this.shown) {
      BUG();
    }
    hideDialog('create_replication_dialog');
    var callback = this.closeCallback;
    this.closeCallback = null;
    if (callback) {
      callback.apply(this, arguments);
    }
  },
  onHide: function () {
    if (this._formObserver) {
      this._formObserver.stopObserving();
      this._formObserver = null;
    }
    this.shown = false;
  },
  formObserver: function (forceRun) {
    forceRun = (forceRun === true);
    var formValues = serializeForm(this.form);
    if (!forceRun && this.previousFormValues === formValues) {
      return;
    }
    this.previousFormValues = formValues;
    var showVerify = (formValues !== this.verifyPassed);
    this.form.find('.replicate-button').need(1).attr('disabled', !!showVerify);
    this.form.find('.verify-button').need(1).attr('disabled', !showVerify);
    if (forceRun) {
      return showVerify;
    }
  },
  onSubmit: function (e) {
    e.preventDefault();
    if (!this.shown) {
      return;
    }
    var showVerify = this.formObserver(true);
    if (showVerify) {
      return this.onVerify();
    }
    return this.onReplicate();
  },
  onVerify: function () {
    var self = this;
    var validateURI = ReplicationsModel.createReplicationURICell.value;
    if (!validateURI) {
      return;
    }
    self.verifyPassed = null;
    var spinner = overlayWithSpinner(self.dialog, null, "Verifying...");
    var formValues = serializeForm(self.form);
    self.showErrors(false);
    postWithValidationErrors(validateURI, formValues, function (data, status) {
      spinner.remove();
      if (status == 'success') {
        self.verifyPassed = formValues;
        self.verifyPassedResult = data;
      } else {
        self.showErrors(data);
      }
      self.formObserver(true);
    });
  },
  onReplicate: function () {
    var self = this;
    var url = self.verifyPassedResult.database;
    var doc = self.verifyPassedResult.document;
    var spinner = overlayWithSpinner(self.dialog, null, "Creating replication...");
    couchReq('POST', url, doc, function () {
      spinner.remove();
      self.close();
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
    if (errors.length === 1 && errors[0].errors) {
      errors = _.values(errors[0].errors).sort();
    }
    renderTemplate('create_replication_dialog_errors', errors);
  }
});

// this turns ReplicationForm into lazily initialized singleton
mkClass.turnIntoLazySingleton(ReplicationForm);

var ReplicationsSection = {
  init: function () {
    renderCellTemplate(ReplicationsModel.remoteClustersListCell, 'cluster_reference_list');

    function replicationInfoValueTransformer(manyInfos) {
      return _.map(manyInfos, function (info) {
        return _.extend({}, info, {
          bucket: info.source,
          to: info.target,
          status: (function (status) {
            switch (status) {
            case 'error':
              return 'Failed';
            case 'triggered':
              return 'Replicating';
            case 'completed':
              return 'Completed';
            case 'cancelled':
              return 'Cancelled';
            }
            return status;
          })(info._replication_state),
          lastRun: (function (tstamp) {
            if (tstamp == null) {
              return;
            }
            var parsed = parseRFC3339Date(tstamp);
            if (parsed) {
              return parsed.valueOf();
            }
          })(info._replication_state_time),
          when: (function (continuous) {
            if (continuous) {
              return "on change";
            } else {
              return "one time sync";
            }
          })(info.continuous)
        });
      });
    }

    renderCellTemplate(ReplicationsModel.currentReplicationInfos,
                       'ongoing_replications_list', {
                         valueTransformer: replicationInfoValueTransformer
                       });

    renderCellTemplate(ReplicationsModel.pastReplicationInfos,
                       'past_replications_list', {
                         valueTransformer: replicationInfoValueTransformer
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
        ReplicationsModel.refreshReplications();
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
  startDeleteReplication: function (id) {
    ThePage.ensureSection("replications");
    var startedDeleteReplication = ReplicationsSection.startedDeleteReplication = {};
    var docURLCell = buildDocURL(ReplicationsModel.replicatorDBURIBaseCell, id);
    var confirmed;

    fetchDocument();
    return;

    function fetchDocument() {
      couchGet(docURLCell, function (doc) {
        if (!doc || startedDeleteReplication !== ReplicationsSection.startedDeleteReplication) {
          // this guards us against a bunch of rapid delete button
          // presses. Only latest delete operation should pass through this gates
          return;
        }

        if (!confirmed) {
          askDeleteConfirmation(doc);
        } else {
          doDelete(doc);
        }
      });
    }

    function askDeleteConfirmation(doc) {
      genericDialog({
        header: "Confirm delete",
        text: "Please, confirm deleting this replication",
        callback: function (e, name, instance) {
          instance.close();
          if (name !== 'ok') {
            return;
          }
          confirmed = true;
          doDelete(doc);
        }
      });
    }

    function doDelete(doc) {
      var url = Cell.needing(docURLCell).compute(function (v, docURL) {
        return docURL + '?' + $.param({rev: doc._rev});
      });
      couchReq('DELETE', url, {}, function () {
        // this is success callback
        ReplicationsModel.refreshReplications();
      }, function (error, status, handleUnexpected) {
        if (status === 404) {
          ReplicationsModel.refreshReplications();
          return;
        }
        if (status === 409) {
          return fetchDocument();
        }
        return handleUnexpected();
      });
    }
  },
  onEnter: function() {
  }
};

configureActionHashParam("deleteReplication", $m(ReplicationsSection, "startDeleteReplication"));
