angular.module('app').controller('appController',
  function ($scope, $templateCache, $http, $modal, $rootScope, $location, pools) {

    _.each(angularTemplatesList, function (url) {
      $http.get("/angular/" + url, {cache: $templateCache});
    });

    $scope.implementationVersion = pools.implementationVersion;

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
