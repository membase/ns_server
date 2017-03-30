(function () {
  "use strict";

  angular
    .module("mnBuckets")
    .controller("mnBucketsListItemController", mnBucketsListItemController);

  function mnBucketsListItemController(mnServersService, $scope) {
    var vm = this;
    vm.getWarmUpProgress = getWarmUpProgress;

    $scope.$watch("bucket", function (bucket) {
      vm.bucketStatus = mnServersService.addNodesByStatus(bucket.nodes);
    }, true);

    function getWarmUpProgress(bucket, tasks) {
      if (!bucket || !tasks) {
        return false;
      }
      var totalPercent = 0;
      var exists = false;
      tasks.tasksWarmingUp.forEach(function (task) {
        if (task.bucket === bucket.name) {
          var message = task.stats.ep_warmup_state;
          exists = true;
          switch (message) {
          case "loading keys":
            totalPercent += ((task.stats.ep_warmup_key_count || 1) / (task.stats.ep_warmup_estimated_key_count || 1)) * 100;
            break;
          case "loading data":
            totalPercent += ((task.stats.ep_warmup_value_count || 1) / (task.stats.ep_warmup_estimated_value_count || 1)) * 100;
            break;
          default:
            return 100;
          }
        }
      });

      return exists ? (totalPercent / bucket.nodes.length) : false;
    }

  }
})();
