(function () {
  "use strict";

  angular
    .module("mnDocuments")
    .controller("mnDocumentsListController", mnDocumentsListController);

  function mnDocumentsListController($scope, $rootScope, mnDocumentsListService, $state, $uibModal, mnPoller, removeEmptyValueFilter) {
    var vm = this;

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
    function lookupSubmit(event) {
      event.preventDefault();

      $state.go('app.admin.documents.editing', {
        documentId: vm.lookupId
      });
      return false;
    }
    function deleteDocument(documentId) {
      return $uibModal.open({
        controller: 'mnDocumentsDeleteDialogController as documentsDeleteDialogCtl',
        templateUrl: 'app/mn_admin/mn_documents/delete_dialog/mn_documents_delete_dialog.html',
        resolve: {
          documentId: function () {
            return documentId;
          }
        }
      });
    }
    function showCreateDialog() {
      return $uibModal.open({
        controller: 'mnDocumentsCreateDialogController as documentsCreateDialogCtl',
        templateUrl: 'app/mn_admin/mn_documents/create_dialog/mn_documents_create_dialog.html',
        resolve: {
          doc: function () {
            return false;
          }
        }
      });
    }
    function onFilterClose(params) {
      params = removeEmptyValueFilter(params);
      params && $state.go('app.admin.documents.control.list', {
        documentsFilter: _.isEmpty(params) ? null : JSON.stringify(params)
      });
    }
    function activate() {
      $rootScope.$broadcast("reloadDocumentsPoller");
    }
  }
})();
