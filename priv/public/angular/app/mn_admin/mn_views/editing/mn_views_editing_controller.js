(function () {
  "use strict";

  angular
    .module("mnViews")
    .controller("mnViewsEditingController", mnViewsEditingController);

  function mnViewsEditingController($scope, $state, $modal, mnPoolDefault, mnHelper, mnViewsEditingService, mnViewsListService, mnPromiseHelper) {
    var vm = this;
    var viewsOptions = {
      lineNumbers: true,
      matchBrackets: true,
      tabSize: 2,
      mode: {
        name: "javascript",
        json: true
      },
      theme: 'default',
      readOnly: false
    };
    vm.viewsOptions = viewsOptions;
    vm.isSpatial = $state.params.isSpatial;
    vm.viewId = $state.params.viewId;
    vm.previewRandomDocument = previewRandomDocument;
    vm.awaitingSampleDocument = awaitingSampleDocument;
    vm.awaitingViews = awaitingViews;
    vm.goToDocumentsSection = goToDocumentsSection;
    vm.isEditDocumentDisabled = isEditDocumentDisabled;
    vm.toggleSampleDocument = toggleSampleDocument;
    vm.isViewsEditorControllsDisabled = isViewsEditorControllsDisabled;
    vm.isPreviewRandomDisabled = isPreviewRandomDisabled;
    vm.toggleViews = toggleViews;
    vm.saveAs = saveAs;
    vm.save = save;
    vm.mnPoolDefault = mnPoolDefault.latestValue();
    vm.isFilterOpened = false;

    if (vm.mnPoolDefault.value.isROAdminCreds) {
      return;
    }

    activate();

    function goToDocumentsSection(e) {
      e.stopImmediatePropagation();
      $state.go("app.admin.documents.editing", {
        documentId: vm.mnViewsEditingState.sampleDocument.meta.id,
        documentsBucket: $state.params.viewsBucket
      });
    }
    function toggleSampleDocument() {
      vm.isSampleDocumentClosed = !vm.isSampleDocumentClosed;
    }
    function toggleViews() {
      vm.isViewsClosed = !vm.isViewsClosed;
    }
    function isEditDocumentDisabled() {
      return awaitingSampleDocument() || !vm.mnViewsEditingState.sampleDocument || vm.mnViewsEditingState.isEmptyState;
    }
    function isPreviewRandomDisabled() {
      return awaitingSampleDocument() || vm.mnViewsEditingState.isEmptyState;
    }
    function isViewsEditorControllsDisabled() {
      return awaitingViews() || vm.mnViewsEditingState.isEmptyState || !vm.mnViewsEditingState.isDevelopmentDocument;
    }
    function awaitingSampleDocument() {
      return !vm.mnViewsEditingState || vm.mnViewsEditingState.sampleDocumentLoading;
    }
    function awaitingViews() {
      return !vm.mnViewsEditingState || vm.mnViewsEditingState.viewsLoading;
    }
    function isViewPathTheSame(current, selected) {
      return current.viewId === selected.viewId && current.isSpatial === selected.isSpatial && current.documentId === selected.documentId;
    }
    function previewRandomDocument(e) {
      e && e.stopImmediatePropagation && e.stopImmediatePropagation();
      mnPromiseHelper(vm.mnViewsEditingState, mnViewsEditingService.prepareRandomDocument($state.params))
        .showSpinner("sampleDocumentLoading")
        .applyToScope("sampleDocument")
        .cancelOnScopeDestroy($scope);
    }
    function saveAs(e) {
      e.stopImmediatePropagation();
      $modal.open({
        controller: 'mnViewsCreateDialogController as mnViewsCreateDialogController',
        templateUrl: 'mn_admin/mn_views/create_dialog/mn_views_create_dialog.html',
        scope: $scope,
        resolve: {
          currentDdoc: mnHelper.wrapInFunction(vm.mnViewsEditingState.currentDocument.doc),
          viewType: mnHelper.wrapInFunction($state.params.isSpatial ? "spatial" : "views")
        }
      }).result.then(function (vm) {
        var selected = {
          documentId: '_design/dev_' + vm.ddoc.name,
          isSpatial: vm.isSpatial,
          viewId: vm.ddoc.view
        };
        if (!isViewPathTheSame($state.params, selected)) {
          $state.go('app.admin.views.editing.result', {
            viewId: selected.viewId,
            documentId: selected.documentId
          });
        }
      });
    }
    function save(e) {
      e.stopImmediatePropagation();
      var url = mnViewsListService.getDdocUrl($state.params.viewsBucket, vm.mnViewsEditingState.currentDocument.doc.meta.id)
      mnPromiseHelper(vm.mnViewsEditingState, mnViewsListService.createDdoc(url, vm.mnViewsEditingState.currentDocument.doc.json))
        .catchErrors("viewsError")
        .showSpinner("viewsLoading")
        .cancelOnScopeDestroy($scope)
        .reloadState();
    }

    function activate() {
      $scope.$watch(isViewsEditorControllsDisabled, function (isDisabled) {
        viewsOptions.readOnly = isDisabled ? 'nocursor' : false;
        viewsOptions.matchBrackets = !isDisabled;
        vm.viewsOptions = viewsOptions;
      });
      $scope.$watch('mnViewsEditingController.mnViewsEditingState.viewsNames.selected', function (selected) {
        selected && !isViewPathTheSame($state.params, selected) && $state.go('app.admin.views.editing.result', {
          viewId: selected.viewId,
          isSpatial: selected.isSpatial,
          documentId: selected.documentId
        });
      });
      return mnPromiseHelper(vm, mnViewsEditingService.getViewsEditingState($state.params))
        .applyToScope("mnViewsEditingState")
        .cancelOnScopeDestroy($scope);
    }
  }
})();
