angular.module('mnWizardStep2Service').factory('mnWizardStep2Service',
  function ($http) {
    var mnWizardStep2Service = {};

    mnWizardStep2Service.model = {
      selected: {},
      sampleBucketsRAMQuota: 0
    };

    mnWizardStep2Service.getSampleBuckets = function () {
      return $http({
        url: '/sampleBuckets',
        method: 'GET'
      });
    }

    mnWizardStep2Service.installSampleBuckets = function () {
      return $http({
        url: '/sampleBuckets/install',
        method: 'POST',
        data: JSON.stringify(_.keys(mnWizardStep2Service.model.selected)),
        timeout: 140000
      });
    }

    return mnWizardStep2Service;
  });