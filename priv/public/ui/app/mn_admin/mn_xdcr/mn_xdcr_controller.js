(function () {
  "use strict";

  angular.module('mnXDCR', [
    'mnXDCRService',
    'mnHelper',
    'mnPromiseHelper',
    'mnPoll',
    'mnAutocompleteOff',
    'mnPoolDefault',
    'mnPools',
    'mnSpinner',
    "ui.codemirror",
    'mnAlertsService'
  ]).controller('mnXDCRController', mnXDCRController);

  function mnXDCRController($scope, permissions, $uibModal, mnHelper, mnPoller, mnPoolDefault, mnXDCRService, mnTasksDetails, mnPromiseHelper) {
    var vm = this;

    vm.mnPoolDefault = mnPoolDefault.latestValue();

    vm.createClusterReference = createClusterReference;
    vm.deleteClusterReference = deleteClusterReference;
    vm.editClusterReference = editClusterReference;
    vm.showReplicationErrors = showReplicationErrors;
    vm.deleteReplication = deleteReplication;
    vm.editReplication = editReplication;
    vm.pausePlayReplication = pausePlayReplication;
    vm.createReplications = createReplications;

    activate();

    vm.to = to;
    vm.humanStatus = humanStatus;
    vm.status = status;

    function to(row) {
      var uuid = row.id.split("/")[0];
      var clusters = vm.references ? vm.references.byUUID : {};
      var toName = !clusters[uuid] ? "unknown" : !clusters[uuid].deleted ? clusters[uuid].name : ('at ' + cluster[uuid].hostname);
      return 'bucket "' + row.target.split('buckets/')[1] + '" on cluster "' + toName + '"';
    }
    function humanStatus(row) {
      if (row.pauseRequested && row.status != 'paused') {
        return 'Paused';
      } else {
        switch (row.status) {
          case 'running': return 'Replicating';
          case 'paused': return 'Paused';
          default: return 'Starting Up';
        }
      }
    }
    function status(row) {
      if (row.pauseRequested && row.status != 'paused') {
        return 'spinner';
      } else {
        switch (row.status) {
        case 'running': return 'pause';
        case 'paused': return 'play';
        default: return 'spinner';
        }
      }
    }

    function activate() {
      if ($scope.rbac.cluster.xdcr.remote_clusters.read) {
        new mnPoller($scope, function () {
          vm.showReferencesSpinner = false;
          return mnXDCRService.getReplicationState();
        })
        .setInterval(10000)
        .subscribe("references", vm)
        .reloadOnScopeEvent("reloadXdcrPoller", vm, "showReferencesSpinner")
        .cycle();
      }
    }
    function createClusterReference() {
      $uibModal.open({
        controller: 'mnXDCRReferenceDialogController as xdcrReferenceDialogCtl',
        templateUrl: 'app/mn_admin/mn_xdcr/reference_dialog/mn_xdcr_reference_dialog.html',
        scope: $scope,
        resolve: {
          reference: mnHelper.wrapInFunction()
        }
      });
    }
    function deleteClusterReference(row) {
      $uibModal.open({
        controller: 'mnXDCRDeleteReferenceDialogController as xdcrDeleteReferenceDialogCtl',
        templateUrl: 'app/mn_admin/mn_xdcr/delete_reference_dialog/mn_xdcr_delete_reference_dialog.html',
        scope: $scope,
        resolve: {
          name: mnHelper.wrapInFunction(row.name)
        }
      });
    }
    function editClusterReference(reference) {
      $uibModal.open({
        controller: 'mnXDCRReferenceDialogController as xdcrReferenceDialogCtl',
        templateUrl: 'app/mn_admin/mn_xdcr/reference_dialog/mn_xdcr_reference_dialog.html',
        scope: $scope,
        resolve: {
          reference: mnHelper.wrapInFunction(reference)
        }
      });
    }
    function createReplications() {
      $uibModal.open({
        controller: 'mnXDCRCreateDialogController as xdcrCreateDialogCtl',
        templateUrl: 'app/mn_admin/mn_xdcr/create_dialog/mn_xdcr_create_dialog.html',
        scope: $scope,
        resolve: {
          replicationSettings: mnHelper.wrapInFunction(mnXDCRService.getReplicationSettings())
        }
      });
    }
    function showReplicationErrors(row) {
      vm.xdcrErrors = row.errors;
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_xdcr/errors_dialog/mn_xdcr_errors_dialog.html',
        scope: $scope
      }).result['finally'](function () {
        delete vm.xdcrErrors;
      });
    }
    function deleteReplication(row) {
      $uibModal.open({
        controller: 'mnXDCRDeleteDialogController as xdcrDeleteDialogCtl',
        templateUrl: 'app/mn_admin/mn_xdcr/delete_dialog/mn_xdcr_delete_dialog.html',
        scope: $scope,
        resolve: {
          id: mnHelper.wrapInFunction(row.id)
        }
      });
    }
    function editReplication(row) {
      $uibModal.open({
        controller: 'mnXDCREditDialogController as xdcrEditDialogCtl',
        templateUrl: 'app/mn_admin/mn_xdcr/edit_dialog/mn_xdcr_edit_dialog.html',
        scope: $scope,
        resolve: {
          id: mnHelper.wrapInFunction(row.id),
          currentSettings: mnHelper.wrapInFunction(mnXDCRService.getReplicationSettings(row.id)),
          globalSettings: mnHelper.wrapInFunction(mnXDCRService.getReplicationSettings())
        }
      });
    }
    function pausePlayReplication(row) {
      mnPromiseHelper(vm, mnXDCRService.saveReplicationSettings(row.id, {pauseRequested: row.status !== 'paused'}))
        .broadcast(["reloadTasksPoller"], {doNotShowSpinner: true});
    };
  }
})();
