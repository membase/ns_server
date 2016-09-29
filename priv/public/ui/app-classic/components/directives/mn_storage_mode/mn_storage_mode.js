(function () {
  "use strict";

  angular
    .module('mnStorageMode', [])
    .directive('mnStorageMode', mnStorageModeDirective)
    .filter('mnFormatStorageModeError', mnFormatStorageModeError);

  function mnFormatStorageModeError() {
    return function (error) {
      switch (error) {
        case "storageMode must be one of forestdb, memory_optimized":
          return "please choose an index storage mode";
        default:
          return error;
      }
    };
  }

   function mnStorageModeDirective() {
    var mnStorageMode = {
      restrict: 'A',
      scope: {
        config: '=mnStorageMode',
        errors: "=",
        isDisabled: "=",
        noLabel: "="
      },
      templateUrl: 'app-classic/components/directives/mn_storage_mode/mn_storage_mode.html'
    };

    return mnStorageMode;
  }
})();
