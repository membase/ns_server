angular.module('mnXDCR', [
  'mnXDCRService',
  'mnHelper',
  'mnBucketsService',
  'mnPromiseHelper',
  'mnPoll',
  'mnRegex',
  'mnPoolDefault',
  'mnSpinner'
]).controller('mnXDCRController',
  function ($scope, $modal, mnHelper, mnPoll, mnPoolDefault, mnXDCRService, mnBucketsService, mnPromiseHelper) {

    //hack for avoiding access to $parent scope from child scope via propery "$parent"
    //should be removed after implementation of Controller As syntax
    $scope.mnXDCRController = $scope;
    $scope.mnPoolDefault = mnPoolDefault.latestValue();

    mnPoll
      .start($scope, mnXDCRService.getReplicationState)
      .subscribe("mnXdcrState")
      .keepIn("app.admin.replications")
      .cancelOnScopeDestroy()
      .run();

    $scope.createClusterReference = function () {
      $modal.open({
        controller: 'mnXDCRReferenceDialogController',
        templateUrl: 'mn_admin/mn_xdcr/reference_dialog/mn_xdcr_reference_dialog.html',
        scope: $scope,
        resolve: {
          reference: mnHelper.wrapInFunction()
        }
      });
    };
    $scope.deleteClusterReference = function (row) {
      $modal.open({
        controller: 'mnXDCRDeleteReferenceDialogController',
        templateUrl: 'mn_admin/mn_xdcr/delete_reference_dialog/mn_xdcr_delete_reference_dialog.html',
        scope: $scope,
        resolve: {
          name: mnHelper.wrapInFunction(row.name)
        }
      });
    };
    $scope.editClusterReference = function (reference) {
      $modal.open({
        controller: 'mnXDCRReferenceDialogController',
        templateUrl: 'mn_admin/mn_xdcr/reference_dialog/mn_xdcr_reference_dialog.html',
        scope: $scope,
        resolve: {
          reference: mnHelper.wrapInFunction(reference)
        }
      });
    };
    $scope.createReplications = function () {
      $modal.open({
        controller: 'mnXDCRCreateDialogController',
        templateUrl: 'mn_admin/mn_xdcr/create_dialog/mn_xdcr_create_dialog.html',
        scope: $scope,
        resolve: {
          buckets: mnHelper.wrapInFunction(mnBucketsService.getBucketsByType()),
          replicationSettings: mnHelper.wrapInFunction(mnXDCRService.getReplicationSettings())
        }
      });
    };
    $scope.showReplicationErrors = function (row) {
      $scope.xdcrErrors = row.errors;
      $modal.open({
        templateUrl: 'mn_admin/mn_xdcr/errors_dialog/mn_xdcr_errors_dialog.html',
        scope: $scope
      }).result['finally'](function () {
        delete $scope.xdcrErrors;
      });
    };
    $scope.deleteReplication = function (row) {
      $modal.open({
        controller: 'mnXDCRDeleteDialogController',
        templateUrl: 'mn_admin/mn_xdcr/delete_dialog/mn_xdcr_delete_dialog.html',
        scope: $scope,
        resolve: {
          id: mnHelper.wrapInFunction(row.id)
        }
      });
    };
    $scope.editReplication = function (row) {
      $modal.open({
        controller: 'mnXDCREditDialogController',
        templateUrl: 'mn_admin/mn_xdcr/edit_dialog/mn_xdcr_edit_dialog.html',
        scope: $scope,
        resolve: {
          id: mnHelper.wrapInFunction(row.id),
          currentSettings: mnHelper.wrapInFunction(mnXDCRService.getReplicationSettings(row.id)),
          globalSettings: mnHelper.wrapInFunction(mnXDCRService.getReplicationSettings())
        }
      });
    };
    $scope.pausePlayReplication = function (row) {
      mnPromiseHelper($scope, mnXDCRService.saveReplicationSettings(row.id, {pauseRequested: row.status !== 'paused'}))
        .reloadState()
        .cancelOnScopeDestroy();
    };
  });