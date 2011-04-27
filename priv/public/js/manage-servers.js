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
var ServersSection = {
  hostnameComparator: mkComparatorByProp('hostname'),
  pendingEject: [], // nodes to eject on next rebalance
  pending: [], // nodes for pending tab
  active: [], // nodes for active tab
  allNodes: [], // all known nodes

  visitTab: function (tabName) {
    if (ThePage.currentSection != 'servers') {
      $('html, body').animate({scrollTop: 0}, 250);
    }
    ThePage.ensureSection('servers');
    this.tabs.setValue(tabName);
  },
  updateData: function () {
    var self = this;
    var serversValue = self.serversCell.value || {};

    _.each("pendingEject pending active allNodes".split(' '), function (attr) {
      self[attr] = serversValue[attr] || [];
    });
  },
  renderEverything: function () {
    this.detailsWidget.prepareDrawing();

    var details = this.poolDetails.value;
    var rebalancing = details && details.rebalanceStatus != 'none';

    var pending = this.pending;
    var active = this.active;

    this.serversQ.find('.add_button').toggle(!!(details && !rebalancing));
    this.serversQ.find('.stop_rebalance_button').toggle(!!rebalancing);

    var mayRebalance = !rebalancing && pending.length !=0;

    if (details && !rebalancing && !details.balanced)
      mayRebalance = true;

    var unhealthyActive = _.detect(active, function (n) {
      return n.clusterMembership == 'active'
        && !n.pendingEject
        && n.status != 'healthy'
    })

    if (unhealthyActive)
      mayRebalance = false;

    var rebalanceButton = this.serversQ.find('.rebalance_button').toggle(!!details);
    rebalanceButton.toggleClass('disabled', !mayRebalance);

    if (details && !rebalancing) {
      $('#rebalance_tab .badge span').text(pending.length);
      $('#rebalance_tab').toggleClass('badge_display', !!pending.length);
    } else {
      $('#rebalance_tab').toggleClass('badge_display', false);
    }

    this.serversQ.toggleClass('rebalancing', !!rebalancing);

    if (!details)
      return;

    if (rebalancing) {
      renderTemplate('manage_server_list', {rows:[], expandingAllowed: false}, $i('pending_server_list_container'));
      return this.renderRebalance(details);
    }

    if (active.length) {
      renderTemplate('manage_server_list', {
        rows: active,
        expandingAllowed: !IOCenter.staleness.value
      }, $i('active_server_list_container'));
      renderTemplate('manage_server_list', {
        rows: pending,
        expandingAllowed: false
      }, $i('pending_server_list_container'));
    }

    if (IOCenter.staleness.value) {
      $('#servers .staleness-notice').show();
      $('#servers').find('.add_button, .rebalance_button').hide();
      $('#active_server_list_container, #pending_server_list_container').find('.re_add_button, .eject_server, .failover_server, .remove_from_list').addClass('disabled');
    } else {
      $('#servers .staleness-notice').hide();
      $('#servers').find('.add_button, .rebalance_button').show();
    }

    $('#active_server_list_container .last-active').find('.eject_server').addClass('disabled').end()
      .find('.failover_server').addClass('disabled');

    $('#active_server_list_container .server_down .eject_server').addClass('disabled');
    $('.failed_over .eject_server, .failed_over .failover_server').hide();
  },
  renderServerDetails: function (item) {
    return this.detailsWidget.renderItemDetails(item);
  },
  renderRebalance: function (details) {
    var progress = this.rebalanceProgress.value;
    if (!progress) {
      progress = {};
    }
    nodes = _.clone(details.nodes);
    nodes.sort(this.hostnameComparator);
    var emptyProgress = {progress: 0};
    _.each(nodes, function (n) {
      var p = progress[n.otpNode];
      if (!p)
        p = emptyProgress;
      n.progress = p.progress;
      n.percent = truncateTo3Digits(n.progress * 100);
    });

    renderTemplate('rebalancing_list', nodes);
  },
  refreshEverything: function () {
    this.updateData();
    this.renderEverything();
  },
  onRebalanceProgress: function () {
    var value = this.rebalanceProgress.value;
    console.log("got progress: ", value);
    if (value.status == 'none') {
      this.poolDetails.invalidate();
      this.rebalanceProgressIsInteresting.setValue(false);
      if (value.errorMessage) {
        displayNotice(value.errorMessage, true);
      }
      return
    }

    this.renderRebalance(this.poolDetails.value);
    this.rebalanceProgress.recalculateAfterDelay(250);
  },
  init: function () {
    var self = this;

    self.poolDetails = DAL.cells.currentPoolDetailsCell;

    self.tabs = new TabsCell("serversTab",
                             "#servers .tabs",
                             "#servers .panes > div",
                             ["active", "pending"]);

    var detailsWidget = self.detailsWidget = new MultiDrawersWidget({
      hashFragmentParam: 'openedServers',
      template: 'server_details',
      elementKey: 'otpNode',
      placeholderCSS: '#servers .settings-placeholder',
      actionLink: 'openServer',
      actionLinkCallback: function () {
        ThePage.ensureSection('servers');
      },
      uriExtractor: function (nodeInfo) {
        return "/nodes/" + encodeURIComponent(nodeInfo.otpNode);
      },
      valueTransformer: function (nodeInfo, nodeSettings) {
        return _.extend({}, nodeInfo, nodeSettings);
      },
      listCell: Cell.compute(function (v) {return v.need(DAL.cells.serversCell).active})
    });

    self.serversCell = DAL.cells.serversCell;

    self.poolDetails.subscribeValue(function (poolDetails) {
      $($.makeArray($('#servers .failover_warning')).slice(1)).remove();
      var warning = $('#servers .failover_warning');

      if (!poolDetails || poolDetails.rebalanceStatus != 'none') {
        return;
      }

      function showWarning(text) {
        warning.after(warning.clone().find('.warning-text').text(text).end().css('display', 'block'));
      }

      _.each(poolDetails.failoverWarnings, function (failoverWarning) {
        switch (failoverWarning) {
        case 'failoverNeeded':
          break;
        case 'rebalanceNeeded':
          showWarning('Rebalance required, some data is not currently replicated!');
          break;
        case 'hardNodesNeeded':
          showWarning('At least two servers are required to provide replication!');
          break;
        case 'softNodesNeeded':
          showWarning('Additional active servers required to provide the desired number of replicas!');
          break;
        case 'softRebalanceNeeded':
          showWarning('Rebalance recommended, some data does not have the desired number of replicas!');
          break;
        default:
          console.log('Got unknown failover warning: ' + failoverSafety);
        }
      });
    });

    self.serversCell.subscribeAny($m(self, "refreshEverything"));

    prepareTemplateForCell('active_server_list', self.serversCell);
    prepareTemplateForCell('pending_server_list', self.serversCell);

    var serversQ = self.serversQ = $('#servers');

    serversQ.find('.rebalance_button').live('click', self.accountForDisabled($m(self, 'onRebalance')));
    serversQ.find('.add_button').live('click', $m(self, 'onAdd'));
    serversQ.find('.stop_rebalance_button').live('click', $m(self, 'onStopRebalance'));

    function mkServerRowHandler(handler) {
      return function (e) {
        var serverRow = $(this).parents(".server_row").get(0) || $(this).parents('.add_back_row').get(0);
        var serverInfo = $.data(serverRow, 'server');
        return handler.call(this, e, serverInfo);
      }
    }

    function mkServerAction(handler) {
      return ServersSection.accountForDisabled(mkServerRowHandler(function (e, serverRow) {
        e.preventDefault();
        return handler(serverRow.hostname);
      }));
    }

    serversQ.find('.re_add_button').live('click', mkServerAction($m(self, 'reAddNode')));
    serversQ.find('.eject_server').live('click', mkServerAction($m(self, 'ejectNode')));
    serversQ.find('.failover_server').live('click', mkServerAction($m(self, 'failoverNode')));
    serversQ.find('.remove_from_list').live('click', mkServerAction($m(self, 'removeFromList')));

    self.rebalanceProgressIsInteresting = new Cell();
    self.rebalanceProgressIsInteresting.setValue(false);
    self.poolDetails.subscribeValue(function (poolDetails) {
      if (poolDetails && poolDetails.rebalanceStatus != 'none')
        self.rebalanceProgressIsInteresting.setValue(true);
    });

    // TODO: should we ignore errors here ?
    this.rebalanceProgress = new Cell(function (interesting, poolDetails) {
      if (!interesting)
        return;
      return future.get({url: poolDetails.rebalanceProgressUri});
    }, {interesting: self.rebalanceProgressIsInteresting,
        poolDetails: self.poolDetails});
    self.rebalanceProgress.keepValueDuringAsync = true;
    self.rebalanceProgress.subscribe($m(self, 'onRebalanceProgress'));
  },
  accountForDisabled: function (handler) {
    return function (e) {
      if ($(e.currentTarget).hasClass('disabled')) {
        e.preventDefault();
        return;
      }
      return handler.call(this, e);
    }
  },
  renderUsage: function (e, totals, withQuotaTotal) {
    var options = {
      topAttrs: {'class': "usage-block"},
      topRight: ['Total', ViewHelpers.formatMemSize(totals.total)],
      items: [
        {name: 'In Use',
         value: totals.usedByData,
         attrs: {style: "background-position:0 -15px;"},
         tdAttrs: {style: "color:#1878A2;"}
        },
        {name: 'Other Data',
         value: totals.used - totals.usedByData,
         attrs: {style: "background-position:0 -30px;"},
         tdAttrs: {style: "color:#C19710;"}},
        {name: 'Free',
         value: totals.total - totals.used}
      ],
      markers: []
    };
    if (withQuotaTotal) {
      options.topLeft = ['Membase Quota', ViewHelpers.formatMemSize(totals.quotaTotal)];
      options.markers.push({value: totals.quotaTotal,
                            attrs: {style: "background-color:#E43A1B;"}});
    }
    $(e).replaceWith(memorySizesGaugeHTML(options));
  },
  onEnter: function () {
    // we need this 'cause switchSection clears rebalancing class
    this.refreshEverything();
  },
  onLeave: function () {
    this.detailsWidget.reset();
  },
  onRebalance: function () {
    var self = this;
    self.postAndReload(self.poolDetails.value.controllers.rebalance.uri,
                       {knownNodes: _.pluck(self.allNodes, 'otpNode').join(','),
                        ejectedNodes: _.pluck(self.pendingEject, 'otpNode').join(',')});
    self.poolDetails.getValue(function () {
      // switch to active server tab when poolDetails reload is complete
      self.tabs.setValue("active");
    });
  },
  onStopRebalance: function () {
    this.postAndReload(this.poolDetails.value.stopRebalanceUri, "");
  },
  validateJoinClusterParams: function (form) {
    var data = {}
    _.each("hostname user password".split(' '), function (name) {
      data[name] = form.find('[name=' + name + ']').val();
    });

    var errors = [];

    if (data['hostname'] == "")
      errors.push("Server IP Address cannot be blank.");
    if (!data['user'] || !data['password'])
      errors.push("Username and Password are both required to join a cluster.");

    if (!errors.length)
      return data;
    return errors;
  },
  onAdd: function () {
    var self = this;
    var uri = self.poolDetails.value.controllers.addNode.uri;

    var dialog = $('#join_cluster_dialog');
    var form = dialog.find('form');
    $('#join_cluster_dialog_errors_container').empty();
    $('#join_cluster_dialog form').get(0).reset();
    dialog.find("input:not([type]), input[type=text], input[type=password]").val('');
    dialog.find('[name=user]').val('Administrator');

    showDialog('join_cluster_dialog', {
      onHide: function () {
        form.unbind('submit');
      }});
    form.bind('submit', function (e) {
      e.preventDefault();

      var errors = self.validateJoinClusterParams(form);
      if (errors.length) {
        renderTemplate('join_cluster_dialog_errors', errors);
        return;
      }

      var confirmed;

      $('#join_cluster_dialog').addClass('overlayed');
      showDialog('add_confirmation_dialog', {
        eventBindings: [['.save_button', 'click', function (e) {
          e.preventDefault();
          confirmed = true;
          hideDialog('add_confirmation_dialog');

          $('#join_cluster_dialog_errors_container').html('');
          var overlay = overlayWithSpinner(form);

          self.poolDetails.setValue(undefined);

          postWithValidationErrors(uri, form, function (data, status) {
            self.poolDetails.invalidate();
            overlay.remove();
            if (status != 'success') {
              renderTemplate('join_cluster_dialog_errors', data)
            } else {
              hideDialog('join_cluster_dialog');
            }
          })
        }]],
        onHide: function () {
          $('#join_cluster_dialog').removeClass('overlayed');
          if (!confirmed)
            hideDialog('join_cluster_dialog'); // cancel pressed on confirmation dialog
        }
      });
    });
  },
  findNode: function (hostname) {
    return _.detect(this.allNodes, function (n) {
      return n.hostname == hostname;
    });
  },
  mustFindNode: function (hostname) {
    var rv = this.findNode(hostname);
    if (!rv) {
      throw new Error("failed to find node info for: " + hostname);
    }
    return rv;
  },
  reDraw: function () {
    this.serversCell.invalidate();
  },
  ejectNode: function (hostname) {
    var self = this;

    var node = self.mustFindNode(hostname);
    if (node.pendingEject)
      return;

    showDialogHijackingSave("eject_confirmation_dialog", ".save_button", function () {
      if (node.clusterMembership == 'inactiveAdded') {
        self.postAndReload(self.poolDetails.value.controllers.ejectNode.uri,
                           {otpNode: node.otpNode});
      } else {
        self.pendingEject.push(node);
        self.reDraw();
      }
    });
  },
  failoverNode: function (hostname) {
    var self = this;
    var node;
    showDialogHijackingSave("failover_confirmation_dialog", ".save_button", function () {
      if (!node)
        throw new Error("must not happen!");
      self.postAndReload(self.poolDetails.value.controllers.failOver.uri,
                         {otpNode: node.otpNode});
    });
    var dialog = $('#failover_confirmation_dialog');
    var overlay = overlayWithSpinner(dialog.find('.content').need(1));
    var statusesCell = DAL.cells.nodeStatusesCell;
    statusesCell.setValue(undefined);
    statusesCell.invalidate();
    statusesCell.changedSlot.subscribeOnce(function () {
      overlay.remove();
      dialog.find('.warning').hide();
      var statuses = statusesCell.value;
      node = statuses[hostname];
      if (!node) {
        hideDialog("failover_confirmation_dialog");
        return;
      }

      var backfill = node.replication < 1;
      var down = node.status != 'healthy';
      var visibleWarning = dialog.find(['.warning', down ? 'down' : 'up', backfill ? 'backfill' : 'no_backfill'].join('_')).show();
      dialog.find('.backfill_percent').text(truncateTo3Digits(node.replication * 100));
      var confirmation = visibleWarning.find('[name=confirmation]')
      if (confirmation.length) {
        confirmation.boolAttr('checked', false);
        function onChange() {
          var checked = !!confirmation.attr('checked');
          dialog.find('.save_button').boolAttr('disabled', !checked);
        }
        function onHide() {
          confirmation.unbind('change', onChange);
          dialog.unbind('dialog:hide', onHide);
        }
        confirmation.bind('change', onChange);
        dialog.bind('dialog:hide', onHide);
        onChange();
      } else {
        dialog.find(".save_button").removeAttr("disabled");
      }
    });
  },
  reAddNode: function (hostname) {
    var node = this.mustFindNode(hostname);
    this.postAndReload(this.poolDetails.value.controllers.reAddNode.uri,
                       {otpNode: node.otpNode});
  },
  removeFromList: function (hostname) {
    var node = this.mustFindNode(hostname);

    if (node.pendingEject) {
      this.serversCell.cancelPendingEject(node);
      return;
    }

    var ejectNodeURI = this.poolDetails.value.controllers.ejectNode.uri;
    this.postAndReload(ejectNodeURI, {otpNode: node.otpNode});
  },
  postAndReload: function (uri, data) {
    var self = this;
    // keep poolDetails undefined for now
    self.poolDetails.setValue(undefined);
    postWithValidationErrors(uri, $.param(data), function (data, status) {
      // re-calc poolDetails according to it's formula
      self.poolDetails.invalidate();
      if (status == 'error' && data[0].mismatch) {
        self.poolDetails.changedSlot.subscribeOnce(function () {
          var msg = "Could not Rebalance because the cluster configuration was modified by someone else.\nYou may want to verify the latest cluster configuration and, if necessary, please retry a Rebalance."
          alert(msg);
        });
      }
    });
  }
};

configureActionHashParam('visitServersTab', $m(ServersSection, 'visitTab'));