(function () {
  "use strict";

  angular.module('mnXDCR', [
    'mnXDCRService',
    'mnHelper',
    'mnBucketsService',
    'mnPromiseHelper',
    'mnPoll',
    'mnRegex',
    'mnPoolDefault',
    'mnSpinner'
  ]).controller('mnXDCRController', mnXDCRController);

  function mnXDCRController($scope, $uibModal, mnHelper, mnPoller, mnPoolDefault, mnXDCRService, mnBucketsService, mnPromiseHelper) {
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

    function activate() {
      new mnPoller($scope, mnXDCRService.getReplicationState)
      .subscribe("state", vm)
      .keepIn("app.admin.replications", vm)
      .cancelOnScopeDestroy()
      .cycle();
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
          buckets: mnHelper.wrapInFunction(mnBucketsService.getBucketsByType()),
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
        .reloadState()
        .cancelOnScopeDestroy($scope);
    };
  }
})();
