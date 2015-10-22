angular.module('mnXDCR').directive('mnXdcrSettings', function (mnHttp, mnPromiseHelper) {

  return {
    restrict: 'A',
    scope: {
      settings: '=mnXdcrSettings'
    },
    isolate: false,
    replace: true,
    templateUrl: 'mn_admin/mn_xdcr/settings/mn_xdcr_settings.html',
    controller: function ($scope, mnPoolDefault) {
      $scope.mnPoolDefault = mnPoolDefault.latestValue();
      $scope.$watch('settings', function (settings) {
        mnPromiseHelper($scope, mnHttp({
          method: 'POST',
          url: '/settings/replications/',
          data: settings,
          params: {
            just_validate: 1
          }
        })).catchErrors().cancelOnScopeDestroy();
      }, true);
    }
  };
});