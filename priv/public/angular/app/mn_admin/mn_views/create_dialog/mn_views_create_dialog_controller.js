angular.module('mnViews').controller('mnViewsCreateDialogController',
  function ($scope, $modal, mnViewsService, mnHelper, $modalInstance, currentDdocName, isSpatial) {
    $scope.ddoc = {};
    $scope.ddoc.name = currentDdocName && mnViewsService.cutOffDesignPrefix(currentDdocName);
    $scope.doesDdocExist = !!currentDdocName;

    function getDdocUrl() {
      return mnViewsService.getDdocUrl($scope.views.bucketsNames.selected, '_design/dev_' + $scope.ddoc.name);
    }

    function createDdoc(presentDdoc) {
      var ddoc = presentDdoc || {views: {}, spatial: {}};
      if (isSpatial) {
        ddoc.spatial[$scope.ddoc.view] = 'function (doc) {\n  if (doc.geometry) {\n    emit(doc.geometry, null);\n  }\n}'
      } else {
        ddoc.views[$scope.ddoc.view] = {
          map: 'function (doc, meta) {\n  emit(meta.id, null);\n}'
        };
      }
      return mnViewsService.createDdoc(getDdocUrl(), ddoc).then(function () {
        $modalInstance.close();
        mnHelper.reloadState();
      });
    }

    $scope.onSubmit = function (ddocForm) {
      if (ddocForm.$invalid || $scope.viewLoading) {
        return;
      }
      $scope.error = false;
      var promise = mnViewsService.getDdoc(getDdocUrl()).then(function (presentDdoc) {
        if (presentDdoc[isSpatial ? 'spatial' : 'views'][$scope.ddoc.view]) {
          $scope.error = 'View with given name already exists';
          return;
        }
        if (!isSpatial && _.keys(presentDdoc.views).length >= 10) {
          return $modal.open({
            templateUrl: '/angular/app/mn_admin/mn_views/confirm_dialog/mn_views_confirm_limit_dialog.html'
          }).result.then(function () {
            return createDdoc(presentDdoc);
          }, function () {
            $modalInstance.close();
          });
        }
        return createDdoc(presentDdoc);
      }, function () {
        return createDdoc();
      });

      mnHelper.showSpinner($scope, promise);
    };
  });
