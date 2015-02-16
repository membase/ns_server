angular.module('app').controller('appController',
  function ($scope, $templateCache, $http, $modal, $rootScope, $location, pools, parseVersionFilter) {

    _.each(angularTemplatesList, function (url) {
      $http.get("/angular/" + url, {cache: $templateCache});
    });

    $rootScope.implementationVersion = pools.implementationVersion;

    $scope.$watchGroup(['implementationVersion', 'tabName'], function (values) {
      var version = parseVersionFilter(values[0]);
      var tabName = values[1];
      $rootScope.mnTitle = (version ? '(' + version[0] + ')' : '') + (tabName ? '-' + tabName : '');
    });
    $scope.showAboutDialog = function () {
      $modal.open({
        templateUrl: '/angular/app/mn_about_dialog.html',
        scope: $scope,
        controller: function ($modalInstance) {
          $scope.cloceAboutDialog = function () {
            $modalInstance.dismiss('cancel');
          };
        }
      });
    };
  });
