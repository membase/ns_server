(function () {
  "use strict";

  angular
    .module("mnDocuments")
    .controller("mnDocumentsListController", mnDocumentsListController);

  function mnDocumentsListController($scope, mnDocumentsListService, $state, $modal, mnPoll, removeEmptyValueFilter) {
    var vm = this;

    vm.nextPage = nextPage;
    vm.prevPage = prevPage;
    vm.isPrevDisabled = isPrevDisabled;
    vm.isNextDisabled = isNextDisabled;
    vm.isEmptyState = isEmptyState;
    vm.lookupSubmit = lookupSubmit;
    vm.showCreateDialog = showCreateDialog;
    vm.deleteDocument = deleteDocument;
    vm.onFilterClose = onFilterClose;
    vm.onFilterReset = onFilterReset;
    vm.filterParams = {};

    try {
      vm.filterInitParams = JSON.parse($state.params.documentsFilter);
    } catch (e) {
      vm.filterInitParams = {};
    }

    vm.filterItems = {
      inclusiveEnd: true,
      endkey: true,
      startkey: true
    };

    activate();

    function onFilterReset() {
      vm.filterInitParams = {};
    }

    function isEmptyState() {
      return !vm.mnDocumentsListState || vm.mnDocumentsListState.isEmptyState;
    }
    function nextPage() {
      $state.go('app.admin.documents.list', {
        pageNumber: vm.mnDocumentsListState.pageNumber + 1
      });
    }
    function prevPage() {
      var prevPage = vm.mnDocumentsListState.pageNumber - 1;
      prevPage = prevPage < 0 ? 0 : prevPage;
      $state.go('app.admin.documents.list', {
        pageNumber: prevPage
      });
    }
    function isPrevDisabled() {
      return isEmptyState() || vm.mnDocumentsListState.pageNumber === 0;
    }
    function isNextDisabled() {
      return isEmptyState() || vm.mnDocumentsListState.isNextDisabled;
    }
    function lookupSubmit(event) {
      event.preventDefault();
      if (isEmptyState()) {
        return;
      }
      $state.go('app.admin.documents.editing', {
        documentId: vm.lookupId
      });
      return false;
    }
    function deleteDocument(documentId) {
      return $modal.open({
        controller: 'mnDocumentsDeleteDialogController as mnDocumentsDeleteDialogController',
        templateUrl: 'mn_admin/mn_documents/delete_dialog/mn_documents_delete_dialog.html',
        resolve: {
          documentId: function () {
            return documentId;
          }
        }
      });
    }
    function showCreateDialog() {
      return $modal.open({
        controller: 'mnDocumentsCreateDialogController as mnDocumentsCreateDialogController',
        templateUrl: 'mn_admin/mn_documents/create_dialog/mn_documents_create_dialog.html',
        resolve: {
          doc: function () {
            return false;
          }
        }
      });
    }
    function onFilterClose(params) {
      params = removeEmptyValueFilter(params);
      params && $state.go('app.admin.documents.list', {
        documentsFilter: _.isEmpty(params) ? null : JSON.stringify(params)
      }, {
        notify: false
      }).then(activate);
    }

    $scope.$watch('mnDocumentsListController.mnDocumentsListState.pageLimits.selected', function (pageLimit) {
      pageLimit && pageLimit !== $state.params.pageLimit && $state.go('app.admin.documents.list', {
        pageLimit: pageLimit
      });
    });

    var poller;

    function activate() {
      poller && poller.stop();
      poller = mnPoll
        .start($scope, function () {
          return mnDocumentsListService.getDocumentsListState($state.params);
        }, 10000)
        .subscribe("mnDocumentsListState", vm)
        .cancelOnScopeDestroy()
        .keepIn("app.admin.documents.list", vm)
        .run();
    }
  }
})();
