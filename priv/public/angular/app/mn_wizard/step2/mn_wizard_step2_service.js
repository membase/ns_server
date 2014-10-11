angular.module('mnWizardStep2Service').factory('mnWizardStep2Service',
  function (mnHttpService) {
    var mnWizardStep2Service = {};

    mnWizardStep2Service.model = {
      selected: {},
      sampleBucketsRAMQuota: 0
    };

    mnWizardStep2Service.getSampleBuckets = mnHttpService({
      url: '/sampleBuckets',
      method: 'GET'
    });

    mnWizardStep2Service.installSampleBuckets = mnHttpService({
      url: '/sampleBuckets/install',
      method: 'POST',
      timeout: 140000
    });

    return mnWizardStep2Service;
  });