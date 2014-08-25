angular.module('mnAdminOverview')
  .controller('mnAdminOverviewController', function ($scope, mnAdminOverviewService) {
    $scope.mnAdminOverviewServiceModel = mnAdminOverviewService.model;

    $scope.mnAdminOverviewServiceModel.ramOverviewConfig = {};
    $scope.mnAdminOverviewServiceModel.hddOverviewConfig = {};

    mnAdminOverviewService.runStatsLoop();

    $scope.$on('$destroy', function () {
      mnAdminOverviewService.stopStatsLoop();
    });
    $scope.$watch('mnAdminOverviewServiceModel.stats', function (stats) {
      if (!stats || !stats.ops.length || !stats.ep_bg_fetched.length) {
        return;
      }

      var now = (new Date()).valueOf();
      var tstamps = stats.timestamp || [];
      var breakInterval;
      if (tstamps.length > 1) {
        breakInterval = (tstamps[tstamps.length-1] - tstamps[0]) /
          Math.min(tstamps.length / 2, 30);
      }

      var options = {
        lastSampleTime: now,
        breakInterval: breakInterval,
        processPlotOptions: function (plotOptions, plotDatas) {
          var firstData = plotDatas[0];
          var t0 = firstData[0][0];
          var t1 = now;
          if (t1 - t0 < 300000) {
            plotOptions.xaxis.ticks = [t0, t1];
            plotOptions.xaxis.tickSize = [null, "minute"];
          }
          return plotOptions;
        }
      };

      $scope.opsGraphConfig = {
        stats: stats['ops'],
        tstamps: tstamps,
        options: options
      };

      $scope.readsGraphConfig = {
        stats: stats['ep_bg_fetched'],
        tstamps: tstamps,
        options: options
      };
    });

    $scope.$watch('mnAdminServiceModel.details', function (details) {
      if (!details) {
        return;
      }

      ;(function () {
        var ram = details.storageTotals.ram;
        var usedQuota = ram.usedByData;
        var bucketsQuota = ram.quotaUsed;
        var quotaTotal = ram.quotaTotal;

        var ramOverviewConfig = {
          // topAttrs: {'class': 'line_cnt'},
          // usageAttrs: {'class': 'usage_biggest'},
          topLeft: {
            name: 'Total Allocated',
            value: _.formatMemSize(bucketsQuota)
          },
          topRight: {
            name: 'Total in Cluster',
            value: _.formatMemSize(quotaTotal)
          },
          items: [{
            name: 'In Use',
            value: usedQuota,
            itemStyle: {'background-color': '#00BCE9', 'z-index': 3},
            labelStyle: {'color':'#1878a2', 'text-align': 'left'}
          }, {
            name: 'Unused',
            value: bucketsQuota - usedQuota,
            itemStyle: {'background-color': '#7EDB49', 'z-index': 2},
            labelStyle: {'color': '#409f05', 'text-align': 'center'}
          }, {
            name: 'Unallocated',
            value: Math.max(quotaTotal - bucketsQuota, 0),
            itemStyle: {'background-color': '#E1E2E3'},
            labelStyle: {'color': '#444245', 'text-align': 'right'}
          }],
          markers: [{
            value: bucketsQuota,
            itemStyle: {'background-color': '#e43a1b'}
          }]
        };
        if (ramOverviewConfig.items[1].value < 0) {
          ramOverviewConfig.items[0].value = bucketsQuota;
          ramOverviewConfig.items[1] = {
            name: 'Overused',
            value: usedQuota - bucketsQuota,
            itemStyle: {'background-color': '#F40015', 'z-index': 4},
            labelStyle: {'color': '#e43a1b'}
          };
          if (usedQuota < quotaTotal) {
            gaugeOptions.items[2].name = 'Available';
            gaugeOptions.items[2].value = quotaTotal - usedQuota;
          } else {
            gaugeOptions.items.length = 2;
            gaugeOptions.markers.push({
              value: quotaTotal,
              itemStyle: {'color': '#444245', 'z-index': 5}
            })
          }
        }

        $scope.mnAdminOverviewServiceModel.ramOverviewConfig = ramOverviewConfig;
      })();

      ;(function () {
        var hdd = details.storageTotals.hdd;

        var usedSpace = hdd.usedByData;
        var total = hdd.total;
        var other = hdd.used - usedSpace;
        var free = hdd.free;

        var hddOverviewConfig = {
          // topAttrs: {'class': 'line_cnt'},
          // usageAttrs: {'class': 'usage_biggest'},
          topLeft: {
            name: 'Usable Free Space',
            value: _.formatMemSize(free)
          },
          topRight: {
            name: 'Total Cluster Storage',
            value: _.formatMemSize(total)
          },
          items: [{
            name: 'In Use',
            value: usedSpace,
            itemStyle: {'background-color': '#00BCE9', 'z-index': 3},
            labelStyle: {'color': '#1878A2', 'text-align': 'left'}
          }, {
            name: 'Other Data',
            value: other,
            itemStyle: {'background-color': '#FDC90D', 'z-index': 2},
            labelStyle: {'color': '#C19710', 'text-align': 'center'}
          }, {
            name: "Free",
            value: total - other - usedSpace,
            itemStyle: {'background-color': '#E1E2E3'},
            labelStyle: {'color': '#444245', 'text-align': 'right'}
          }],
          markers: [{
            value: other + usedSpace + free,
            itemStyle: {'background-color': '#E43A1B'}
          }]
        };

        $scope.mnAdminOverviewServiceModel.hddOverviewConfig = hddOverviewConfig;
      })();
    }, true);
  });