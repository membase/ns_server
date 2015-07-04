angular.module('mnMemoryQuota', [
  'mnServices'
]).directive('mnMemoryQuota', function () {

  return {
    restrict: 'A',
    scope: {
      config: '=mnMemoryQuota',
      errors: "="
    },
    templateUrl: 'components/directives/mn_memory_quota/mn_memory_quota.html'
  };
});