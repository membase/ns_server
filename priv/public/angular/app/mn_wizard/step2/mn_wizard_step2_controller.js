angular.module('mnWizard').controller('mnWizardStep2Controller',
  function ($scope, mnWizardStep2Service) {
    $scope.mnWizardStep2ServiceModel = mnWizardStep2Service.model;

    $scope.$watch('mnWizardStep2ServiceModel.selected', function (selected) {
      $scope.mnWizardStep2ServiceModel.sampleBucketsRAMQuota = _.reduce(selected, add, 0);
    }, true);

    function add(memo, num) {
      return memo + Number(num);
    }

    mnWizardStep2Service.getSampleBuckets().success(function (buckets) {
      $scope.viewLoading = false;
      $scope.sampleBuckets = buckets;
    });
  });