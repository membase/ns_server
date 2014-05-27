angular.module('wizard')
  .controller('wizard.step2.Controller',
    ['$scope', '$q', 'wizard.step2.service',
      function ($scope, $q, step2Service) {
        $scope.spinner = true;
        $scope.focusMe = true;
        $scope.modelStep2Service = step2Service.model;

        $scope.$watch('modelStep2Service.selected', function (selected) {
          $scope.modelStep2Service.sampleBucketsRAMQuota = _.reduce(selected, add, 0);
        }, true);

        function add(memo, num) {
          return memo + Number(num);
        }

        step2Service.getSampleBuckets().success(function (buckets) {
          $scope.spinner = false;
          $scope.sampleBuckets = buckets;
        });
      }]);