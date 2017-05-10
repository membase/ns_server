(function () {
  "use strict";

  angular.module('mnSettingsAutoFailover', [
    'mnSettingsAutoFailoverService',
    'mnHelper',
    'mnPromiseHelper'
  ]).controller('mnSettingsAutoFailoverController', mnSettingsAutoFailoverController);

  function mnSettingsAutoFailoverController($scope, $q, mnHelper, mnPromiseHelper, mnSettingsAutoFailoverService, mnPoolDefault) {
    var vm = this;

    vm.submit = submit;

    activate();

    function getAutoFailoverSettings() {
      return {
        enabled: vm.autoFailoverSettings.enabled,
        timeout: vm.autoFailoverSettings.timeout
      };
    }

    function getReprovisionSettings() {
      return {
        enabled: vm.reprovisionSettings.enabled,
        maxNodes: vm.reprovisionSettings.max_nodes
      };
    }

    function watchOnSettings(method, dataFunc) {
      return function () {
        if (!$scope.rbac.cluster.settings.write) {
          return;
        }
        mnPromiseHelper(vm, mnSettingsAutoFailoverService[method](dataFunc(), {just_validate: 1}))
          .catchErrorsFromSuccess(method + "Errors");
      }
    }

    function activate() {
      if (mnPoolDefault.export.compat.atLeast50) {
        mnPromiseHelper(vm, mnSettingsAutoFailoverService.getAutoReprovisionSettings())
          .applyToScope(function (resp) {
            vm.reprovisionSettings = resp.data;

            $scope.$watch(
              'settingsAutoFailoverCtl.reprovisionSettings',
              _.debounce(watchOnSettings("postAutoReprovisionSettings", getReprovisionSettings),
                         500, {leading: true}), true);
          });
      }

      mnPromiseHelper(vm,
        mnSettingsAutoFailoverService.getAutoFailoverSettings())
        .applyToScope(function (resp) {
          vm.autoFailoverSettings = resp.data;

          $scope.$watch(
            'settingsAutoFailoverCtl.autoFailoverSettings',
            _.debounce(watchOnSettings("saveAutoFailoverSettings", getAutoFailoverSettings),
                       500, {leading: true}), true);
        });
    }

    function submit() {
      var queries = [
        mnPromiseHelper(vm, mnSettingsAutoFailoverService.saveAutoFailoverSettings(getAutoFailoverSettings()))
          .catchErrors(function (resp) {
            vm.saveAutoFailoverSettingsErrors = resp && {timeout: resp};
          })
          .getPromise()
      ];

      if (mnPoolDefault.export.compat.atLeast50) {
        queries.push(
          mnPromiseHelper(vm, mnSettingsAutoFailoverService.postAutoReprovisionSettings(getReprovisionSettings()))
            .catchErrors(function (resp) {
              vm.postAutoReprovisionSettingsErrors = resp && {maxNodes: resp};
            })
            .getPromise()
        );
      }

      mnPromiseHelper(vm, $q.all(queries))
        .catchErrors()
        .showGlobalSpinner()
        .showGlobalSuccess("Settings saved successfully!");
    };
  }
})();
