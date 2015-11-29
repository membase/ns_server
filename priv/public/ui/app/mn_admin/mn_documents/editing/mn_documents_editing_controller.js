(function () {
  "use strict";

  angular
    .module("mnDocuments")
    .controller("mnDocumentsEditingController", mnDocumentsEditingController);

  function mnDocumentsEditingController($scope, $state, $uibModal, mnDocumentsEditingService, mnPromiseHelper) {
    var vm = this;
    var editorOptions = {
      lineNumbers: true,
      matchBrackets: false,
      tabSize: 2,
      mode: {
        name: "javascript",
        json: true
      },
      theme: 'default',
      readOnly: 'nocursor',
      onLoad: codemirrorLoaded
    };
    vm.editorOptions = editorOptions;
    vm.isDeleteDisabled = isDeleteDisabled;
    vm.isSaveAsDisabled = isSaveAsDisabled;
    vm.isSaveDisabled = isSaveDisabled;
    vm.isEditorDisabled = isEditorDisabled;
    vm.areThereWarnings = areThereWarnings;
    vm.saveAsDialog = saveAsDialog;
    vm.deleteDocument = deleteDocument;
    vm.save = save;

    function save() {
      mnPromiseHelper(vm, mnDocumentsEditingService.createDocument($state.params, vm.mnDocumentsEditingState.doc))
        .cancelOnScopeDestroy($scope)
        .showSpinner()
        .catchErrors();
    }
    function codemirrorLoaded(cm) {
      activate().then(function (resp) {
        if (resp.doc) {
          cm.on("change", function (doc) {
            vm.isDocumentChanged = !documentIsNotChanged(doc.historySize());
            onDocValueUpdate(doc.getValue());
          });
        }
      });
    }
    function deleteDocument(documentId) {
      return $uibModal.open({
        controller: 'mnDocumentsDeleteDialogController as documentsDeleteDialogCtl',
        templateUrl: 'app/mn_admin/mn_documents/delete_dialog/mn_documents_delete_dialog.html',
        resolve: {
          documentId: function () {
            return vm.mnDocumentsEditingState.title;
          }
        }
      }).result.then(function () {
        $state.go("app.admin.documents.list");
      });
    }
    function saveAsDialog() {
      return $uibModal.open({
        controller: 'mnDocumentsCreateDialogController as documentsCreateDialogCtl',
        templateUrl: 'app/mn_admin/mn_documents/create_dialog/mn_documents_create_dialog.html',
        resolve: {
          doc: function () {
            return vm.mnDocumentsEditingState.doc;
          }
        }
      }).result.then(function (resp) {
        $state.go("app.admin.documents.editing", {
          documentId: resp.documentId
        });
      })
    }
    function documentIsNotChanged(history) {
      return history.redo == 0 && history.undo == 1;
    }
    function areThereWarnings() {
      return vm.mnDocumentsEditingState && _.chain(vm.mnDocumentsEditingState.editorWarnings).values().some().value();
    }
    function areThereErrors() {
      return !!vm.mnDocumentsEditingState.errors || areThereWarnings();
    }
    function isEditorDisabled() {
      return !vm.mnDocumentsEditingState ||
             (vm.mnDocumentsEditingState.editorWarnings &&
             (vm.mnDocumentsEditingState.editorWarnings.notFound ||
              vm.mnDocumentsEditingState.editorWarnings.documentIsBase64 ||
              vm.mnDocumentsEditingState.editorWarnings.documentLimitError));

    }
    function isDeleteDisabled() {
      return !vm.mnDocumentsEditingState ||
              vm.viewLoading ||
             (vm.mnDocumentsEditingState.editorWarnings && vm.mnDocumentsEditingState.editorWarnings.notFound);
    }
    function isSaveAsDisabled() {
      return !vm.mnDocumentsEditingState ||
              vm.viewLoading ||
              areThereErrors();
    }
    function isSaveDisabled() {
      return !vm.mnDocumentsEditingState ||
              vm.viewLoading ||
             !vm.isDocumentChanged ||
             areThereErrors();
    }
    function onDocValueUpdate(json) {
      vm.mnDocumentsEditingState.errors = null;
      vm.mnDocumentsEditingState.editorWarnings = {
        documentLimitError: mnDocumentsEditingService.isJsonOverLimited(json)
      };

      if (!vm.mnDocumentsEditingState.editorWarnings.documentLimitError) {
        try {
          var parsedJSON = JSON.parse(json);
        } catch (error) {
          vm.mnDocumentsEditingState.errors = {
            reason: error.message,
            error: "Invalid document"
          };
          return false;
        }
        vm.mnDocumentsEditingState.editorWarnings["shouldNotBeNull"] = _.isNull(parsedJSON);
        vm.mnDocumentsEditingState.editorWarnings["shouldBeAnObject"] = !_.isObject(parsedJSON);
        vm.mnDocumentsEditingState.editorWarnings["shouldNotBeAnArray"] = _.isArray(parsedJSON);
      }

      return areThereWarnings() ? false : parsedJSON;
    }
    function activate() {
      $scope.$watch(isEditorDisabled, function (isDisabled) {
        editorOptions.readOnly = isDisabled ? 'nocursor' : false;
        editorOptions.matchBrackets = !isDisabled;
        vm.editorOptions = editorOptions;
      });
      return mnPromiseHelper(vm, mnDocumentsEditingService.getDocumentsEditingState($state.params))
        .applyToScope("mnDocumentsEditingState")
        .cancelOnScopeDestroy($scope)
        .getPromise();
    }
  }
})();
