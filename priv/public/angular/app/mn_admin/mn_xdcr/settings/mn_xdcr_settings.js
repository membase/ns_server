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
      $scope.$watch('settings', function (settings) {
        mnHelper.promiseHelper($scope, mnHttp({
          method: 'POST',
          url: '/settings/replications/',
          data: settings,
          params: {
            just_validate: 1
          }
        })).catchErrorsFromSuccess();
      }, true);
    }
  };
});