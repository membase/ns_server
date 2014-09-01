angular.module('mnAdminOverviewService').factory('mnAdminOverviewService',
  function ($http, $timeout) {
    var mnAdminOverviewService = {};

    mnAdminOverviewService.model = {};

    var statsLoopTimeout;

    function runStatsLoop(stats) {
      if (!stats) {
        return;
      }
      mnAdminOverviewService.model.stats = stats;

      if (statsLoopTimeout) {
        mnAdminOverviewService.clearStatsTimeout();
      }

      var ts = stats.timestamp;
      var interval = ts[ts.length - 1] - ts[0];
      if (isNaN(interval) || interval < 15000) {
        statsLoopTimeout = $timeout(mnAdminOverviewService.runStatsLoop, 15000);
      } else if (interval < 300000) {
        statsLoopTimeout = $timeout(mnAdminOverviewService.runStatsLoop, 10000);
      } else {
        statsLoopTimeout = $timeout(mnAdminOverviewService.runStatsLoop, 30000);
      }
    }

    mnAdminOverviewService.clearStatsTimeout = function () {
      $timeout.cancel(statsLoopTimeout);
    };

    mnAdminOverviewService.runStatsLoop = function () {
      $http({url: '/pools/default/overviewStats', method: "GET"}).success(runStatsLoop);
    };

    return mnAdminOverviewService;
  });
