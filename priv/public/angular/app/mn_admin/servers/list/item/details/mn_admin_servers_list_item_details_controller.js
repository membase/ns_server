angular.module('mnAdminServers')
  .controller('mnAdminServersListItemDetailsController',
    function ($scope, $location, mnAdminService, mnAdminTasksService, mnAdminServersListItemDetailsService) {
      $scope.$watch('mnAdminServiceModel.details', updateDetails);

      $scope.$watch(function () {
        return $location.search()['openedServers'];
      }, updateDetails, true);

      function updateDetails() {
        var currentlyOpened = _.wrapToArray($location.search()['openedServers']);

        if (_.contains(currentlyOpened, $scope.node && $scope.node.hostname)) {
          mnAdminServersListItemDetailsService.getNodeDetails($scope.node).success(function (details) {

            details.uptime = _.formatUptime(details.uptime);

            $scope.details = details;

            if (details.storage.hdd[0]) {
              $scope.ellipsisPath = _.ellipsisiseOnLeft(details.storage.hdd[0].path || "", 25);
            }
          });
        }
      }
      function getBaseConfig(totals) {
        return {
          topRight: {
            name: 'Total',
            value: _.formatMemSize(totals.total)
          },
          items: [{
            name: 'In Use',
            value: totals.usedByData,
            itemStyle: {'background-color': '#00BCE9'},
            labelStyle: {'color': '#1878A2', 'text-align': 'left'}
          }, {
            name: 'Other Data',
            value: totals.used - totals.usedByData,
            itemStyle: {"background-color": "#FDC90D"},
            labelStyle: {"color": "#C19710",  'text-align': 'center'}
          }, {
            name: 'Free',
            value: totals.total - totals.used,
            itemStyle: {},
            labelStyle: {'text-align': 'right'}
          }],
          markers: []
        };
      }
      $scope.$watch('details.storageTotals.hdd', function (totals) {
        if (!totals) {
          return;
        }
        $scope.getDiskStorageConfig = getBaseConfig(totals);
      });
      $scope.$watch('details.storageTotals.ram', function (totals) {
        if (!totals) {
          return;
        }

        var memoryCacheConfig = getBaseConfig(totals);
        memoryCacheConfig.topLeft = {
          name: 'Couchbase Quota',
          value: _.formatMemSize(totals.quotaTotal)
        }
        memoryCacheConfig.markers.push({
          track: 1,
          value: totals.quotaTotal,
          itemStyle: {"background-color": "#E43A1B"}
        });
        $scope.getMemoryCacheConfig = memoryCacheConfig;
      });

      $scope.$watch('mnAdminTasksServiceModel.tasksRebalance', function (task) {
        if (!task) {
          return;
        }
        var rebalanceTask = task.status === 'running' && task;
        if (rebalanceTask &&
              rebalanceTask.detailedProgress &&
              rebalanceTask.detailedProgress.bucket &&
              rebalanceTask.detailedProgress.bucketNumber !== undefined &&
              rebalanceTask.detailedProgress.bucketsCount !== undefined &&
              rebalanceTask.detailedProgress.perNode &&
              rebalanceTask.detailedProgress.perNode[$scope.node.otpNode]) {
            $scope.detailedProgress = {};

            var ingoing = rebalanceTask.detailedProgress.perNode[$scope.node.otpNode].ingoing;
            if (ingoing.activeVBucketsLeft != 0 ||
                ingoing.replicaVBucketsLeft != 0 ||
                ingoing.docsTotal != 0 ||
                ingoing.docsTransferred != 0) {
              $scope.detailedProgress.ingoing = ingoing;
            } else {
              $scope.detailedProgress.ingoing = false;
            }

            var outgoing = rebalanceTask.detailedProgress.perNode[$scope.node.otpNode].outgoing;
            if (outgoing.activeVBucketsLeft != 0 ||
                outgoing.replicaVBucketsLeft != 0 ||
                outgoing.docsTotal != 0 ||
                outgoing.docsTransferred != 0) {
              $scope.detailedProgress.outgoing = outgoing;
            } else {
              $scope.detailedProgress.outgoing = false;
            }

            $scope.detailedProgress.bucket = rebalanceTask.detailedProgress.bucket;
            $scope.detailedProgress.bucketNumber = rebalanceTask.detailedProgress.bucketNumber;
            $scope.detailedProgress.bucketsCount = rebalanceTask.detailedProgress.bucketsCount;
          } else {
            $scope.detailedProgress = false;
          }
      });
    });