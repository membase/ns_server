angular.module('mnXDCR').directive('mnXdcrSettings', function (mnHttp) {

  return {
    restrict: 'A',
    scope: {
      settings: '=mnXdcrSettings'
    },
    isolate: false,
    replace: true,
    templateUrl: 'mn_admin/mn_xdcr/settings/mn_xdcr_settings.html',
    controller: function ($scope) {
      function onResult(resp) {
        $scope.errors = resp.data;
      }
      $scope.$watch('settings', function (settings) {
        mnHttp({
          method: 'POST',
          url: '/settings/replications/',
          data: settings,
          params: {
            just_validate: 1
          }
        }).then(onResult, onResult);
      }, true);
    }
  };
});