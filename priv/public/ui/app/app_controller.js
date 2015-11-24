(function () {
  "use strict";

  angular
    .module('app')
    .controller('appController', appController)
    .controller('showAboutDialogController', showAboutDialogController);

  function appController($scope, $templateCache, $http, $rootScope, $uibModal, pools, parseVersionFilter) {
    var vm = this;

    vm.showAboutDialog = showAboutDialog;
    vm.implementationVersion = pools.implementationVersion;

    activate();

    function activate() {
      _.each(angularTemplatesList, function (url) {
        $http.get(url, {cache: $templateCache});
      });
      $scope.$watchGroup(['appController.implementationVersion', 'appController.tabName'], watchGroup);
    }

    function watchGroup(values) {
      var version = parseVersionFilter(values[0]);
      var tabName = values[1];
      $rootScope.mnTitle = (version ? '(' + version[0] + ')' : '') + (tabName ? '-' + tabName : '');
    }
    function showAboutDialog() {
      $uibModal.open({
        templateUrl: 'app/mn_about_dialog.html',
        controller: "showAboutDialogController as showAboutDialogController",
        resolve: {
          implementationVersion: function () {
            return pools.implementationVersion;
          }
        }
      });
    };
  }

  function showAboutDialogController(implementationVersion) {
    var vm = this;
    vm.implementationVersion = implementationVersion;
  }
})();
