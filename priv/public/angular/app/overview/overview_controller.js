angular.module('overview', [])
  .controller('overview.Controller',
    ['$scope', 'overview.service', 'app.service',
      function ($scope, overviewService, appService) {
        $scope.model = overviewService.model;

        $scope.model.ramOverviewConfig = {};
        $scope.model.hddOverviewConfig = {};

        appService.$watch('details', function (details) {
          if (!details) {
            return
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
                itemStyle: {'background-color': '#00BCE9'},
                labelStyle: {'color':'#1878a2', 'text-align': 'left'}
              }, {
                name: 'Unused',
                value: bucketsQuota - usedQuota,
                itemStyle: {'background-color': '#7EDB49'},
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
                itemStyle: {'background-color': '#F40015'},
                labelStyle: {'color': '#e43a1b'}
              };
              if (usedQuota < quotaTotal) {
                gaugeOptions.items[2].name = 'Available';
                gaugeOptions.items[2].value = quotaTotal - usedQuota;
              } else {
                gaugeOptions.items.length = 2;
                gaugeOptions.markers.push({
                  value: quotaTotal,
                  itemStyle: {'color': '#444245'}
                })
              }
            }

            $scope.model.ramOverviewConfig = ramOverviewConfig;
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
                itemStyle: {'background-color': '#00BCE9'},
                labelStyle: {'color': '#1878A2', 'text-align': 'left'}
              }, {
                name: 'Other Data',
                value: other,
                itemStyle: {'background-color': '#FDC90D'},
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

            $scope.model.hddOverviewConfig = hddOverviewConfig;
          })();
        });
      }]);