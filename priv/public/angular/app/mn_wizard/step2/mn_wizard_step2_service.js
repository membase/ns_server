angular.module('mnWizardStep2Service').factory('mnWizardStep2Service',
  function (mnHttp) {
    var mnWizardStep2Service = {};
    var sampleBucketsRAMQuota = 0;
    var selectedSamples = {};

    mnWizardStep2Service.setSelected = function (selected) {
      selectedSamples = selected;
      sampleBucketsRAMQuota = _.reduce(selected, function (memo, num) {
        return memo + Number(num);
      }, 0);
    };

    mnWizardStep2Service.getSampleBucketsRAMQuota = function () {
      return sampleBucketsRAMQuota;
    };

    mnWizardStep2Service.isSomeBucketSelected = function () {
      return sampleBucketsRAMQuota !== 0;
    };

    mnWizardStep2Service.getSampleBuckets = function () {
      return mnHttp({
        url: '/sampleBuckets',
        method: 'GET'
      });
    };

    mnWizardStep2Service.installSampleBuckets = function () {
      return mnHttp({
        url: '/sampleBuckets/install',
        method: 'POST',
        timeout: 140000,
        data: JSON.stringify(_.keys(selectedSamples))
      });
    };

    return mnWizardStep2Service;
  });