angular.module('mnServices', [
]).directive('mnServices', function () {

  return {
    restrict: 'A',
    scope: {
      config: '=mnServices'
    },
    templateUrl: 'components/directives/mn_services/mn_services.html'
  };
});