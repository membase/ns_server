(function () {
  "use strict";

  angular
    .module('mnXDCR')
    .directive('mnXdcrSettings', mnXdcrSettingsDirective);

    function mnXdcrSettingsDirective($http, mnPromiseHelper) {
      var mnXdcrSettings = {
        restrict: 'A',
        scope: {
          settings: '=mnXdcrSettings',
          mnPoolDefault: "=",
          mnPools: "="
        },
        isolate: false,
        replace: true,
        templateUrl: 'app/mn_admin/mn_xdcr/settings/mn_xdcr_settings.html',
        controller: controller,
        controllerAs: "xdcrSettingsCtl",
        bindToController: true
      };

      return mnXdcrSettings;

      function controller($scope) {
        var vm = this;
        $scope.$watch('xdcrSettingsCtl.settings', function (settings) {
          mnPromiseHelper(vm, $http({
            method: 'POST',
            url: '/settings/replications/',
            data: settings,
            params: {
              just_validate: 1
            }
          })).catchErrors();
        }, true);
      }
    }
})();
