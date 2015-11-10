angular.module('mnTasksDetails', [
  'mnHttp'
]).factory('mnTasksDetails',
  function (mnHttp, $cacheFactory) {
    var mnTasksDetails = {};

    // if (!rv.rebalancing) {
    //   if (sawRebalanceRunning && task.errorMessage) {
    //     sawRebalanceRunning = false;
    //     // displayNotice(task.errorMessage, true);
    //   }
    // } else {
    //   sawRebalanceRunning = true;
    // }

    mnTasksDetails.get = function () {
      return mnHttp({
        url: '/pools/default/tasks',
        method: 'GET',
        cache: true
      }).then(function (resp) {
        var rv = {};
        var tasks = resp.data;

        rv.tasks = tasks;
        rv.tasksRecovery = _.detect(tasks, detectRecoveryTasks);
        rv.tasksRebalance = _.detect(tasks, detectRebalanceTasks);
        rv.tasksWarmingUp = _.filter(tasks, detectWarmupTask);
        rv.inRebalance = !!(rv.tasksRebalance && rv.tasksRebalance.status === "running");
        rv.inRecoveryMode = !!rv.tasksRecovery;
        rv.isLoadingSamples = !!_.detect(tasks, detectLoadingSamples);
        rv.stopRecoveryURI = rv.tasksRecovery && rv.tasksRecovery.stopURI;
        rv.isSubtypeGraceful = rv.tasksRebalance.subtype === 'gracefulFailover';
        rv.running = _.filter(tasks, function (task) {
          return task.status === "running";
        });
        rv.isOrphanBucketTask = !!_.detect(tasks, detectOrphanBucketTask);

        return rv;
      });
    };

    function detectOrphanBucketTask(taskInfo) {
      return taskInfo.type === "orphanBucket";
    }

    function detectRecoveryTasks(taskInfo) {
      return taskInfo.type === "recovery";
    }

    function detectRebalanceTasks(taskInfo) {
      return taskInfo.type === "rebalance";
    }

    function detectLoadingSamples(taskInfo) {
      return taskInfo.type === "loadingSampleBucket" && taskInfo.status === "running";
    }

    function detectWarmupTask(task) {
      return task.type === 'warming_up' && task.status === 'running';
    }

    mnTasksDetails.clearCache = function () {
      $cacheFactory.get('$http').remove('/pools/default/tasks');
      return this;
    };

    mnTasksDetails.getFresh = function () {
      return mnTasksDetails.clearCache().get();
    };

    return mnTasksDetails;
  });
