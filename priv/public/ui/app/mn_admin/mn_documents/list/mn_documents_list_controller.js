(function () {
  "use strict";

  angular
    .module("mnDocuments")
    .controller("mnDocumentsListController", mnDocumentsListController);

  function mnDocumentsListController($scope, $rootScope, mnDocumentsListService, $state, $uibModal, removeEmptyValueFilter) {
    var vm = this;

    vm.lookupSubmit = lookupSubmit;
    vm.showCreateDialog = showCreateDialog;
    vm.deleteDocument = deleteDocument;
    vm.onFilterClose = onFilterClose;
    vm.onFilterReset = onFilterReset;

    var filterConfig = {};

    try {
      filterConfig.params = JSON.parse($state.params.documentsFilter);
    } catch (e) {
      filterConfig.params = {};
    }

    filterConfig.items = {
      inclusiveEnd: true,
      endkey: true,
      startkey: true
    };

    vm.filterConfig = filterConfig;

    activate();

    function onFilterReset() {
      vm.filterConfig.params = {};
    }
    function lookupSubmit() {
      vm.lookupId && $state.go('^.^.editing', {
        documentId: vm.lookupId
      });
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
    function onFilterClose() {
      var params = filterConfig.params;
      params = removeEmptyValueFilter(params);
      params && $state.go('^.list', {
        documentsFilter: _.isEmpty(params) ? null : JSON.stringify(params)
      });
    }
    function activate() {
      $rootScope.$broadcast("reloadDocumentsPoller");
    }
  }
})();
