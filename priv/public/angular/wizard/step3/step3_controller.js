angular.module('wizard')
  .controller('wizard.step3.Controller',
    ['$scope', '$state', 'wizard.step3.service', 'wizard.step2.service', 'wizard.step1.joinCluster.service',
      function ($scope, $state, step3Service, step2Service, joinClusterService) {
        $scope.guageConfig = {};
        $scope.focusMe = true;
        $scope.replicaNumberEnabled = true;

        step3Service.model.bucketConf.ramQuotaMB = joinClusterService.model.dynamicRamQuota - _.bytesToMB(step2Service.model.sampleBucketsRAMQuota);
        $scope.modelStep3Service = step3Service.model;

        $scope.onSubmit = function onSubmit() {
          if (!_.isEmpty($scope.errors)) {
            return;
          }
          $state.transitionTo('wizard.step4');
        }

        $scope.$watch('replicaNumberEnabled', function (isEnabled) {
          if (!isEnabled) {
            $scope.modelStep3Service.bucketConf.replicaNumber = 0;
            $scope.modelStep3Service.bucketConf.replicaIndex = 0;
          } else {
            $scope.modelStep3Service.bucketConf.replicaNumber = 1;
          }
        });

        $scope.$watch('modelStep3Service.bucketConf', function (bucketConf) {
          if (!bucketConf) {
            return;
          }
          step3Service.postBuckets(true).success(onResult).error(onResult);
        }, true);

        function onResult(result) {
          if (!result) {
            return;
          }
          var ramSummary = result.summaries.ramSummary;

          $scope.totalBucketSize = _.bytesToMB(ramSummary.thisAlloc * ramSummary.nodesCount);
          $scope.nodeCount = _.count(ramSummary.nodesCount, 'node');
          $scope.perNodeMegs = ramSummary.perNodeMegs

          $scope.errors = result.errors || {};

          var options = {
            topRight: {
              name: 'Cluster quota',
              value: _.formatMemSize(ramSummary.total)
            },
            items: [{
              name: 'Other Buckets',
              value: ramSummary.otherBuckets,
              itemStyle: {'background-color': '#00BCE9', 'z-index': '2'},
              labelStyle: {'color': '#1878a2', 'text-align': 'left'}
            }, {
              name: 'This Bucket',
              value: ramSummary.thisAlloc,
              itemStyle: {'background-color': '#7EDB49', 'z-index': '1'},
              labelStyle: {'color': '#409f05', 'text-align': 'center'}
            }, {
              name: 'Free',
              value: ramSummary.total - ramSummary.otherBuckets - ramSummary.thisAlloc,
              itemStyle: {'background-color': '#E1E2E3'},
              labelStyle: {'color': '#444245', 'text-align': 'right'}
            }],
            markers: []
          };

          if (options.items[2].value < 0) {
            options.items[1].value = ramSummary.total - ramSummary.otherBuckets;
            options.items[2] = {
              name: 'Overcommitted',
              value: ramSummary.otherBuckets + ramSummary.thisAlloc - ramSummary.total,
              itemStyle: {'background-color': '#F40015'},
              labelStyle: {'color': '#e43a1b'}
            };
            options.markers.push({
              value: ramSummary.total,
              itemStyle: {'background-color': '#444245'}
            });
            options.markers.push({
              value: ramSummary.otherBuckets + ramSummary.thisAlloc,
              itemStyle: {'background-color': 'red'}
            });
            options.topLeft = {
              name: 'Total Allocated',
              value: _.formatMemSize(ramSummary.otherBuckets + ramSummary.thisAlloc),
              itemStyle: {'color': '#e43a1b'}
            };
          }

          $scope.guageConfig = options;
        }
      }]);