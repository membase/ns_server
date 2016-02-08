(function () {
  "use strict";

  angular
    .module('mnStorageMode', [])
    .directive('mnStorageMode', mnStorageModeDirective);

   function mnStorageModeDirective() {
    var mnStorageMode = {
      restrict: 'A',
      scope: {
        config: '=mnStorageMode',
        errors: "=",
        isDisabled: "=",
        noLabel: "="
      },
      templateUrl: 'app/components/directives/mn_storage_mode/mn_storage_mode.html'
    };

    return mnStorageMode;
  }
})();
