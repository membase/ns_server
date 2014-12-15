angular.module('mnWarmupProgress').directive('mnWarmupProgress', function () {
  return {
    restrict: 'A',
    scope: {
      warmUpTasks: '=',
      sortBy: '@'
    },
    replace: true,
    templateUrl: 'components/directives/mn_warmup_progress/mn_warmup_progress.html'
  };
}).filter('formatWarmupMessage', function () {
  return function (task) {
    var message = task.stats.ep_warmup_state;
    switch (message) {
      case "loading keys":
        return message + " (" + task.stats.ep_warmup_key_count + " / " + task.stats.ep_warmup_estimated_key_count + ")";
      case "loading data":
        return message + " (" + task.stats.ep_warmup_value_count + " / " + task.stats.ep_warmup_estimated_value_count + ")";
      default:
        return message;
    }
  };
});