angular.module('mnWizard').controller('mnWizardStep2Controller',
  function ($scope, mnWizardStep2Service, sampleBuckets) {
    $scope.selected = {};
    $scope.$watch('selected', mnWizardStep2Service.setSelected, true);
    $scope.sampleBuckets = sampleBuckets.data;
  });