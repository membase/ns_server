angular.module('mnViews', [
  'mnViewsService',
  'mnCompaction',
  'mnHelper',
  'mnPromiseHelper',
  'mnPoll'
]).controller('mnViewsController',
  function ($scope, $modal, $state, buckets, mnHelper, mnViewsService, mnCompaction, mnPoll) {

    if ($state.params.viewsBucket) {
      $scope.$watch('views.bucketsNames.selected', function (selectedBucket) {
        selectedBucket && selectedBucket !== $state.params.viewsBucket && $state.go('app.admin.views', {
          viewsBucket: selectedBucket
        });
      });
    } else {
      return $state.go('app.admin.views', {
        viewsBucket: buckets.byType.membase.defaultName
      });
    }


    var poll = mnPoll.start($scope, function () {
      return mnViewsService.getViewsState($state.params);
    }).subscribe("views");

    $scope.showCreationDialog = function (ddoc, isSpatial) {
      $modal.open({
        controller: 'mnViewsCreateDialogController',
        templateUrl: '/angular/app/mn_admin/mn_views/create_dialog/mn_views_create_dialog.html',
        scope: $scope,
        resolve: {
          currentDdocName: mnHelper.wrapInFunction(ddoc && ddoc.meta.id),
          isSpatial: mnHelper.wrapInFunction(isSpatial)
        }
      });
    };
    $scope.showDdocDeletionDialog = function (ddoc) {
      $modal.open({
        controller: 'mnViewsDeleteDdocDialogController',
        templateUrl: '/angular/app/mn_admin/mn_views/delete_ddoc_dialog/mn_views_delete_ddoc_dialog.html',
        scope: $scope,
        resolve: {
          currentDdocName: mnHelper.wrapInFunction(ddoc.meta.id)
        }
      });
    };
    $scope.showViewDeletionDialog = function (ddoc, viewName, isSpatial) {
      $modal.open({
        controller: 'mnViewsDeleteViewDialogController',
        templateUrl: '/angular/app/mn_admin/mn_views/delete_view_dialog/mn_views_delete_view_dialog.html',
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
        mnViewsService.createDdoc(url, ddoc).then(function () {
          $state.go('app.admin.views', {
            type: 'production'
          });
        });
      };
    }
    $scope.publishDdoc = function (ddoc) {
      var url = mnViewsService.getDdocUrl($scope.views.bucketsNames.selected, "_design/" + mnViewsService.cutOffDesignPrefix(ddoc.meta.id));
      var publish = prepareToPublish(url, ddoc.json);
      var promise = mnViewsService.getDdoc(url).then(function (presentDdoc) {
        $modal.open({
          templateUrl: '/angular/app/mn_admin/mn_views/confirm_dialogs/mn_views_confirm_override_dialog.html'
        }).result.then(publish);
      }, publish);
    };
    $scope.copyToDev = function (ddoc) {
      $modal.open({
        controller: 'mnViewsCopyDialogController',
        templateUrl: '/angular/app/mn_admin/mn_views/copy_dialog/mn_views_copy_dialog.html',
        scope: $scope,
        resolve: {
          currentDdoc: mnHelper.wrapInFunction(ddoc)
        }
      });
    };

    $scope.registerCompactionAsTriggeredAndPost = function (row) {
      row.disableCompact = true;
      mnCompaction.registerAsTriggeredAndPost(row.controllers.compact).then(poll.restart);
    };
    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);
  });