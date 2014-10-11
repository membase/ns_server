angular.module('mnAdminTasksService').factory('mnAdminTasksService',
  function (mnHttpService) {
    var mnAdminTasksService = {};

    mnAdminTasksService.model = {};

    mnAdminTasksService.runTasksLoop = mnHttpService({
      method: 'GET',
      keepURL: true,
      success: [runTasksLoop, populateModel]
    });

    var prevPeriod;

    function runTasksLoop(tasks) {
      var minPeriod = 1 << 28;
      _.each(tasks, function (taskInfo) {
        var period = taskInfo.recommendedRefreshPeriod;
        if (!period) {
          return;
        }
        period = (period * 1000) >> 0;
        if (period < minPeriod) {
          minPeriod = period;
        }
      });

      if (prevPeriod === minPeriod) {
        return;
      }
      prevPeriod = minPeriod;
      mnAdminTasksService.runTasksLoop({period: minPeriod});
    }

    mnAdminTasksService.stopTasksLoop = mnAdminTasksService.runTasksLoop.cancel

    function populateModel(tasks) {
      if (!tasks) {
        return;
      }
      var model = mnAdminTasksService.model;

      model.tasksRecovery = _.detect(tasks, detectRecoveryTasks);
      model.tasksRebalance = _.detect(tasks, detectRebalanceTasks);
      model.inRebalance = !!(model.tasksRebalance && model.tasksRebalance.status === "running");
      model.inRecoveryMode = !!model.tasksRecovery;
      model.isLoadingSamples = !!_.detect(tasks, detectLoadingSamples);
      model.stopRecoveryURI = model.tasksRecovery && model.tasksRecovery.stopURI;
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

    return mnAdminTasksService;
  });
