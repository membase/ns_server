(function () {
  "use strict";

  angular
    .module('mnXDCR')
    .directive('mnXdcrSettings', mnXdcrSettingsDirective);

    function mnXdcrSettingsDirective(mnHttp, mnPromiseHelper) {
      var mnXdcrSettings = {
        restrict: 'A',
        scope: {
          settings: '=mnXdcrSettings'
        },
        isolate: false,
        replace: true,
        templateUrl: 'app/mn_admin/mn_xdcr/settings/mn_xdcr_settings.html',
        controller: controller,
        controllerAs: "xdcrSettingsCtl",
        bindToController: true
      };

      return mnXdcrSettings;

      function controller($scope, mnPoolDefault) {
        var vm = this;
        vm.mnPoolDefault = mnPoolDefault.latestValue();
        $scope.$watch('xdcrSettingsCtl.settings', function (settings) {
          mnPromiseHelper(vm, mnHttp({
            method: 'POST',
            url: '/settings/replications/',
            data: settings,
            params: {
              just_validate: 1
            }
          })).catchErrors().cancelOnScopeDestroy($scope);
        }, true);
      }
    }
})();