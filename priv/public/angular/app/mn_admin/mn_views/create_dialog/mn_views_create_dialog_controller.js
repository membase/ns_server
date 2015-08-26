angular.module('mnViews').controller('mnViewsCreateDialogController',
  function ($scope, $modal, $q, mnViewsService, mnHelper, mnPromiseHelper, $modalInstance, currentDdocName, isSpatial) {
    $scope.ddoc = {};
    $scope.isSpatial = isSpatial;
    $scope.ddoc.name = currentDdocName && mnViewsService.cutOffDesignPrefix(currentDdocName);
    $scope.doesDdocExist = !!currentDdocName;

    function getDdocUrl() {
      return mnViewsService.getDdocUrl($scope.views.bucketsNames.selected, '_design/dev_' + encodeURIComponent($scope.ddoc.name));
    }

    function createDdoc(presentDdoc) {
      var ddoc = presentDdoc || {json: {}};
      var key = isSpatial ? 'spatial' : 'views';
      var views = ddoc.json[key] || (ddoc.json[key] = {});
      if (isSpatial) {
        views[$scope.ddoc.view] = 'function (doc) {\n  if (doc.geometry) {\n    emit(doc.geometry, null);\n  }\n}'
      } else {
        views[$scope.ddoc.view] = {
          map: 'function (doc, meta) {\n  emit(meta.id, null);\n}'
        };
      }

      return mnViewsService.createDdoc(getDdocUrl(), ddoc.json);
    }

    $scope.onSubmit = function (ddocForm) {
      if (ddocForm.$invalid || $scope.viewLoading) {
        return;
      }
      $scope.error = false;
      var promise = mnViewsService.getDdoc(getDdocUrl()).then(function (presentDdoc) {
        var key = isSpatial ? 'spatial' : 'views';
        var views = presentDdoc.json[key] || (presentDdoc.json[key] = {});
        if (views[$scope.ddoc.view]) {
          return $q.reject({
            data: {
              reason: 'View with given name already exists'
            }
          });
        }
        if (_.keys(views).length >= 10) {
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

      mnPromiseHelper($scope, promise, $modalInstance)
        .showSpinner()
        .prepareErrors(function (resp) {
          $scope.error = resp.data.reason;
        })
        .reloadState()
        .closeOnSuccess();
    };
  });
