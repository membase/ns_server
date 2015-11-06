(function () {
  "use strict";

  angular
    .module("mnViews")
    .controller("mnViewsCreateDialogController", mnViewsCreateDialogController);

  function mnViewsCreateDialogController($scope, $uibModal, $state, $q, mnViewsListService, mnHelper, mnPromiseHelper, $uibModalInstance, currentDdoc, viewType) {
    var vm = this;
    var isViewsEditingSection = $state.is('app.admin.views.editing.result');
    vm.ddoc = {};
    vm.isSpatial = viewType === "spatial";
    vm.ddoc.name = currentDdoc && mnViewsListService.cutOffDesignPrefix(currentDdoc.meta.id);
    vm.doesDdocExist = !!currentDdoc;
    if (isViewsEditingSection) {
      vm.ddoc.view = $state.params.viewId;
    }
    vm.isCopy = isViewsEditingSection;
    vm.onSubmit = onSubmit;

    function getDdocUrl() {
      return mnViewsListService.getDdocUrl($state.params.viewsBucket, '_design/dev_' + encodeURIComponent(vm.ddoc.name));
    }

    function createDdoc(presentDdoc) {
      var ddoc = presentDdoc || {json: {}};
      var views = ddoc.json[viewType] || (ddoc.json[viewType] = {});
      if (vm.isCopy) {
        views[vm.ddoc.view] = currentDdoc.json[viewType][$state.params.viewId];
      } else {
        if (vm.isSpatial) {
          views[vm.ddoc.view] = 'function (doc) {\n  if (doc.geometry) {\n    emit(doc.geometry, null);\n  }\n}'
        } else {
          views[vm.ddoc.view] = {
            map: 'function (doc, meta) {\n  emit(meta.id, null);\n}'
          };
        }
      }

      return mnPromiseHelper(vm, mnViewsListService.createDdoc(getDdocUrl(), ddoc.json))
        .cancelOnScopeDestroy($scope)
        .getPromise();
    }

    function onSubmit(ddocForm) {
      if (ddocForm.$invalid || vm.viewLoading) {
        return;
      }
      vm.error = false;
      var promise = mnViewsListService.getDdoc(getDdocUrl()).then(function (presentDdoc) {
        var views = presentDdoc.json[viewType] || (presentDdoc.json[viewType] = {});
        if (views[vm.ddoc.view] && !vm.isCopy) {
          return $q.reject({
            data: {
              reason: 'View with given name already exists'
            }
          });
        }
        if (_.keys(views).length >= 10) {
          return $uibModal.open({
            templateUrl: 'app/mn_admin/mn_views/confirm_dialogs/mn_views_confirm_limit_dialog.html'
          }).result.then(function () {
            return createDdoc(presentDdoc);
          }, function () {
            $uibModalInstance.close();
          });
        }
        return createDdoc(presentDdoc);
      }, function () {
        return createDdoc();
      });

      mnPromiseHelper(vm, promise, $uibModalInstance)
        .showSpinner()
        .cancelOnScopeDestroy($scope)
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    };

  }
})();
