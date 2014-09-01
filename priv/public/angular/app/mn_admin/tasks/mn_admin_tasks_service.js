angular.module('mnAdminTasksService').factory('mnAdminTasksService',
  function ($http, $timeout, $q) {
    var mnAdminTasksService = {};
    var tasksLoopTimeout;
    var tasksLoopCanceler;

    mnAdminTasksService.model = {};

    mnAdminTasksService.stopTasksLoop = function () {
      $timeout.cancel(tasksLoopTimeout);
      tasksLoopCanceler && tasksLoopCanceler.resolve();
    };
    mnAdminTasksService.runTasksLoop = function (url) {
      if (!url) {
        return
      }
      tasksLoopCanceler && tasksLoopCanceler.resolve();
      tasksLoopCanceler = $q.defer();

      return $http({
        method: 'GET',
        url: url,
        timeout: tasksLoopCanceler.promise
      }).success(function (tasks) {
        runTasksLoop(tasks, url);
      });
    };

    function populateModel(tasks) {

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

    function runTasksLoop(tasks, url) {
      if (!tasks) {
        return;
      }

      populateModel(tasks);

      if (tasksLoopTimeout) {
        $timeout.cancel(tasksLoopTimeout);
      }

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

      tasksLoopTimeout = $timeout(function () {
        mnAdminTasksService.runTasksLoop(url);
      }, minPeriod);
    }

    return mnAdminTasksService;
  });
