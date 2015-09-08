angular.module('mnViews', [
  'mnViewsService',
  'mnCompaction',
  'mnHelper',
  'mnPromiseHelper',
  'mnPoll'
]).controller('mnViewsController',
  function ($scope, $modal, $state, mnHelper, mnViewsService, mnCompaction, mnPoll, poolDefault, mnPromiseHelper) {

    $scope.isKvNode = poolDefault.isKvNode;
    mnPromiseHelper($scope, mnViewsService.getKvNodeLink())
      .applyToScope("kvNodeLink")
      .cancelOnScopeDestroy();

    if (!poolDefault.isKvNode) {
      return;
    }

    $scope._ = _;

    mnPoll
      .start($scope, function () {
        return mnViewsService.getViewsState($state.params);
      })
      .subscribe("mnViewsState")
      .keepIn()
      .cancelOnScopeDestroy()
      .run();

    $scope.$watch(function () {
      return $scope.mnViewsState && $scope.mnViewsState.bucketsNames.selected && $scope.mnViewsState.isDevelopmentViews && !$scope.mnViewsState.ddocsAreInFactMissing;
    }, function (showViewCreationButtons) {
      $scope.showViewCreationButtons = showViewCreationButtons;
    });

    $scope.$watch('mnViewsState.bucketsNames.selected', function (selectedBucket) {
      selectedBucket && selectedBucket !== $state.params.viewsBucket && $state.go('app.admin.views', {
        viewsBucket: selectedBucket
      });
    });

    $scope.showCreationDialog = function (ddoc, isSpatial) {
      $modal.open({
        controller: 'mnViewsCreateDialogController',
        templateUrl: 'mn_admin/mn_views/create_dialog/mn_views_create_dialog.html',
        scope: $scope,
        resolve: {
          currentDdocName: mnHelper.wrapInFunction(ddoc && ddoc.meta.id),
          isSpatial: mnHelper.wrapInFunction(isSpatial)
        }
      });
    };
    $scope.showMapreduceCreationDialog = function () {
      $scope.showCreationDialog(undefined, false);
    };
    $scope.showSpatialCreationDialog = function () {
      $scope.showCreationDialog(undefined, true);
    };
    $scope.showDdocDeletionDialog = function (ddoc) {
      $modal.open({
        controller: 'mnViewsDeleteDdocDialogController',
        templateUrl: 'mn_admin/mn_views/delete_ddoc_dialog/mn_views_delete_ddoc_dialog.html',
        scope: $scope,
        resolve: {
          currentDdocName: mnHelper.wrapInFunction(ddoc.meta.id)
        }
      });
    };
    $scope.showViewDeletionDialog = function (ddoc, viewName, isSpatial) {
      $modal.open({
        controller: 'mnViewsDeleteViewDialogController',
        templateUrl: 'mn_admin/mn_views/delete_view_dialog/mn_views_delete_view_dialog.html',
        scope: $scope,
        resolve: {
          currentDdocName: mnHelper.wrapInFunction(ddoc.meta.id),
          currentViewName: mnHelper.wrapInFunction(viewName),
          isSpatial: mnHelper.wrapInFunction(isSpatial)
        }
      });
    };
    function prepareToPublish(url, ddoc) {
      return function () {
        mnPromiseHelper($scope, mnViewsService.createDdoc(url, ddoc.json))
          .onSuccess(function () {
            $state.go('app.admin.views', {
              type: 'production'
            });
          })
          .cancelOnScopeDestroy();
      };
    }
    $scope.publishDdoc = function (ddoc) {
      var url = mnViewsService.getDdocUrl($scope.mnViewsState.bucketsNames.selected, "_design/" + mnViewsService.cutOffDesignPrefix(ddoc.meta.id));
      var publish = prepareToPublish(url, ddoc);
      mnPromiseHelper($scope, mnViewsService.getDdoc(url))
        .onSuccess(function (presentDdoc) {
          $modal.open({
            templateUrl: 'mn_admin/mn_views/confirm_dialogs/mn_views_confirm_override_dialog.html'
          }).result.then(publish);
        }, publish)
        .cancelOnScopeDestroy();
    };
    $scope.copyToDev = function (ddoc) {
      $modal.open({
        controller: 'mnViewsCopyDialogController',
        templateUrl: 'mn_admin/mn_views/copy_dialog/mn_views_copy_dialog.html',
        scope: $scope,
        resolve: {
          currentDdoc: mnHelper.wrapInFunction(ddoc)
        }
      });
    };

    $scope.registerCompactionAsTriggeredAndPost = function (row) {
      row.disableCompact = true;
      mnPromiseHelper($scope, mnCompaction.registerAsTriggeredAndPost(row.controllers.compact))
        .reloadState()
        .cancelOnScopeDestroy();
    };
  });