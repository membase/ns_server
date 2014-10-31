angular.module('mnAdminOverviewService').factory('mnAdminOverviewService',
  function (mnHttp, mnDateService, mnPoolDetails) {
    var mnAdminOverviewService = {};

    var processPlotOptions = function (plotOptions, plotDatas) {
      var firstData = plotDatas[0];
      var t0 = firstData[0][0];
      var t1 = this.lastSampleTime;
      if (t1 - t0 < 300000) {
        plotOptions.xaxis.ticks = [t0, t1];
        plotOptions.xaxis.tickSize = [null, "minute"];
      }
      return plotOptions;
    };

    var ramOverviewConfigBase = {
      topLeft: {
        name: 'Total Allocated'
      },
      topRight: {
        name: 'Total in Cluster'
      },
      items: [{
        name: 'In Use',
        itemStyle: {'background-color': '#00BCE9', 'z-index': 3},
        labelStyle: {'color':'#1878a2', 'text-align': 'left'}
      }, {
        name: 'Unused',
        itemStyle: {'background-color': '#7EDB49', 'z-index': 2},
        labelStyle: {'color': '#409f05', 'text-align': 'center'}
      }, {
        name: 'Unallocated',
        itemStyle: {'background-color': '#E1E2E3'},
        labelStyle: {'color': '#444245', 'text-align': 'right'}
      }],
      markers: [{
        itemStyle: {'background-color': '#e43a1b'}
      }]
    };

    var hddOverviewConfigBase = {
      topLeft: {
        name: 'Usable Free Space'
      },
      topRight: {
        name: 'Total Cluster Storage'
      },
      items: [{
        name: 'In Use',
        itemStyle: {'background-color': '#00BCE9', 'z-index': 3},
        labelStyle: {'color': '#1878A2', 'text-align': 'left'}
      }, {
        name: 'Other Data',
        itemStyle: {'background-color': '#FDC90D', 'z-index': 2},
        labelStyle: {'color': '#C19710', 'text-align': 'center'}
      }, {
        name: "Free",
        itemStyle: {'background-color': '#E1E2E3'},
        labelStyle: {'color': '#444245', 'text-align': 'right'}
      }],
      markers: [{
        itemStyle: {'background-color': '#E43A1B'}
      }]
    };

    mnAdminOverviewService.getStats = function () {
      return mnHttp({
        url: '/pools/default/overviewStats',
        method: "GET"
      }).then(function (statsResponse) {
        var stats = statsResponse.data;
        var now = (mnDateService.newDate()).valueOf();
        var tstamps = stats.timestamp || [];
        var interval = tstamps[tstamps.length - 1] - tstamps[0];
        var breakInterval = (tstamps.length > 1) ? (interval / Math.min(tstamps.length / 2, 30)) : undefined;

        if (!stats || !stats.ops.length || !stats.ep_bg_fetched.length) {
          return;
        }

        var options = {
          lastSampleTime: now,
          breakInterval: breakInterval,
          processPlotOptions: processPlotOptions
        };

        return {
          opsGraphConfig: {
            stats: stats['ops'],
            tstamps: tstamps,
            options: options
          },
          readsGraphConfig: {
            stats: stats['ep_bg_fetched'],
            tstamps: tstamps,
            options: options
          }
        };
      });
    };

    mnAdminOverviewService.getOverviewConfig = function () {
      return mnPoolDetails.getFresh().then(function (poolsDetails) {
        var details = poolsDetails;
        var rv = {};

        (function () {
          var ram = details.storageTotals.ram;
          var usedQuota = ram.usedByData;
          var bucketsQuota = ram.quotaUsed;
          var quotaTotal = ram.quotaTotal;

          var ramOverviewConfig = _.clone(ramOverviewConfigBase, true);

          ramOverviewConfig.topLeft.value = _.formatMemSize(bucketsQuota);
          ramOverviewConfig.topRight.value = _.formatMemSize(quotaTotal);
          ramOverviewConfig.items[0].value = usedQuota;
          ramOverviewConfig.items[1].value = bucketsQuota - usedQuota;
          ramOverviewConfig.items[2].value = Math.max(quotaTotal - bucketsQuota, 0);
          ramOverviewConfig.markers[0].value = bucketsQuota

          if (ramOverviewConfig.items[1].value < 0) {
            ramOverviewConfig.items[0].value = bucketsQuota;
            ramOverviewConfig.items[1] = {
              name: 'Overused',
              value: usedQuota - bucketsQuota,
              itemStyle: {'background-color': '#F40015', 'z-index': 4},
              labelStyle: {'color': '#e43a1b'}
            };
            if (usedQuota < quotaTotal) {
              ramOverviewConfig.items[2].name = 'Available';
              ramOverviewConfig.items[2].value = quotaTotal - usedQuota;
            } else {
              ramOverviewConfig.items.length = 2;
              ramOverviewConfig.markers.push({
                value: quotaTotal,
                itemStyle: {'color': '#444245', 'z-index': 5}
              })
            }
          }

          rv.ramOverviewConfig = ramOverviewConfig;
        })();

        ;(function () {
          var hdd = details.storageTotals.hdd;

          var usedSpace = hdd.usedByData;
          var total = hdd.total;
          var other = hdd.used - usedSpace;
          var free = hdd.free;

          var hddOverviewConfig = _.clone(hddOverviewConfigBase, true);

          hddOverviewConfig.topLeft.value = _.formatMemSize(free);
          hddOverviewConfig.topRight.value = _.formatMemSize(total);
          hddOverviewConfig.items[0].value = usedSpace;
          hddOverviewConfig.items[1].value = other;
          hddOverviewConfig.items[2].value = total - other - usedSpace;
          hddOverviewConfig.markers[0].value = other + usedSpace + free;

          rv.hddOverviewConfig = hddOverviewConfig;
        })();

        return rv;
      });
    };

    return mnAdminOverviewService;
  });
