(function () {
  "use strict";

  angular
    .module("mnAboutDialogService", [
      "mnBucketsService",
      "mnPools",
      "ui.bootstrap",
      "mnFilters",
      "mnPoolDefault"
    ])
    .factory("mnAboutDialogService", mnAboutDialogFactory);

  function mnAboutDialogFactory($http, $q, $uibModal, mnPools, mnBucketsService, mnIntegerToStringFilter, mnPoolDefault) {
    var mnAboutDialogService = {
      getState: getState,
      showAboutDialog: showAboutDialog
    };

    return mnAboutDialogService;

    function showAboutDialog() {
      $uibModal.open({
        templateUrl: 'app/mn_about_dialog/mn_about_dialog.html',
        controller: "mnAboutDialogController as aboutDialogCtl"
      });
    }

    function getVersion() {
      return $http({
        url: "/versions",
        method: "GET"
      }).then(function (resp) {
        return resp.data;
      });
    }

    function getState() {
      return mnPools.get().then(function (pools) {
        if (!pools.isInitialized) {
          return getVersion();
        }
        return {implementationVersion: pools.implementationVersion};
      }, getVersion);
    }
  }
})();
