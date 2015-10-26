(function () {
  "use strict";

  angular
    .module("mnSettings")
    .controller("mnSettingsController", mnSettingsController);

  function mnSettingsController($scope, poolDefault) {
    var vm = this;
    vm.poolDefault = poolDefault;
  }
})();
