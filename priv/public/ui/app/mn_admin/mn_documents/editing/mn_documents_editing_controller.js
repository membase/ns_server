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
      mnPromiseHelper(vm, mnDocumentsEditingService.createDocument($state.params, vm.state.doc))
        .showSpinner()
        .catchErrors()
        .onSuccess(function () {
          vm.isDocumentChanged = false;
        });
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
        templateUrl: 'mn_admin/mn_documents/delete_dialog/mn_documents_delete_dialog.html',
        resolve: {
          documentId: function () {
            return vm.state.title;
          }
        }
      }).result.then(function () {
        $state.go("app.admin.documents.control.list");
      });
    }
    function saveAsDialog() {
      return $uibModal.open({
        controller: 'mnDocumentsCreateDialogController as documentsCreateDialogCtl',
        templateUrl: 'mn_admin/mn_documents/create_dialog/mn_documents_create_dialog.html',
        resolve: {
          doc: function () {
            return vm.state.doc;
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
      return vm.state && _.chain(vm.state.editorWarnings).values().some().value();
    }
    function areThereErrors() {
      return !!vm.state.errors || areThereWarnings();
    }
    function isEditorDisabled() {
      return !vm.state ||
             (vm.state.editorWarnings &&
             (vm.state.editorWarnings.notFound ||
              vm.state.editorWarnings.documentIsBase64 ||
              vm.state.editorWarnings.documentLimitError)) ||
             ($scope.rbac.cluster.bucket[$state.params.documentsBucket] &&
             !$scope.rbac.cluster.bucket[$state.params.documentsBucket].data.write);

    }
    function isDeleteDisabled() {
      return !vm.state ||
              vm.viewLoading ||
             (vm.state.editorWarnings && vm.state.editorWarnings.notFound);
    }
    function isSaveAsDisabled() {
      return !vm.state ||
              vm.viewLoading ||
              areThereErrors();
    }
    function isSaveDisabled() {
      return !vm.state ||
              vm.viewLoading ||
             !vm.isDocumentChanged ||
             areThereErrors();
    }
    function onDocValueUpdate(json) {
      vm.state.errors = null;
      vm.state.editorWarnings = {
        documentLimitError: mnDocumentsEditingService.isJsonOverLimited(json)
      };

      if (!vm.state.editorWarnings.documentLimitError) {
        try {
          var parsedJSON = JSON.parse(json);
        } catch (error) {
          vm.state.errors = {
            reason: error.message,
            error: "Invalid document"
          };
          return false;
        }
        vm.state.editorWarnings["shouldNotBeNull"] = _.isNull(parsedJSON);
        vm.state.editorWarnings["shouldBeAnObject"] = !_.isObject(parsedJSON);
        vm.state.editorWarnings["shouldNotBeAnArray"] = _.isArray(parsedJSON);
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
        .applyToScope("state")
        .getPromise();
    }
  }
})();
