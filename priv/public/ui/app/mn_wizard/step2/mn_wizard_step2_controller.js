angular.module('mnWizard').controller('mnWizardStep2Controller',
  function ($scope, mnWizardStep2Service, mnPromiseHelper, mnSettingsSampleBucketsService) {
    $scope.selected = {};
    $scope.$watch('selected', mnWizardStep2Service.setSelected, true);
    mnPromiseHelper($scope, mnSettingsSampleBucketsService.getSampleBuckets())
      .cancelOnScopeDestroy()
      .applyToScope("sampleBuckets");
  });