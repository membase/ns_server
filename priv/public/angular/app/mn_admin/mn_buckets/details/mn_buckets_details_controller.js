angular.module('mnBuckets').controller('mnBucketsDetailsController',
  function ($scope, mnBucketsDetailsService) {
    $scope.$watch('bucket', function () {
      mnBucketsDetailsService.getDetails($scope.bucket).then(function (details) {
        _.extend($scope, details);
      });
    });
  });