angular.module('app').controller('appController',
  function ($scope, $templateCache, $http, $uibModal, $rootScope, $location, pools, parseVersionFilter) {

    _.each(angularTemplatesList, function (url) {
      $http.get(url, {cache: $templateCache});
    });

    $rootScope.implementationVersion = pools.implementationVersion;

    $scope.$watchGroup(['implementationVersion', 'tabName'], function (values) {
      var version = parseVersionFilter(values[0]);
      var tabName = values[1];
      $rootScope.mnTitle = (version ? '(' + version[0] + ')' : '') + (tabName ? '-' + tabName : '');
    });
    $scope.showAboutDialog = function () {
      $uibModal.open({
        templateUrl: 'app/mn_about_dialog.html',
        scope: $scope,
        controller: function ($uibModalInstance) {
          $scope.cloceAboutDialog = function () {
            $uibModalInstance.dismiss('cancel');
          };
        }
      });
    };
  });
