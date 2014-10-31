angular.module('mnWizardStep2Service').factory('mnWizardStep2Service',
  function (mnHttp) {
    var mnWizardStep2Service = {};
    var sampleBucketsRAMQuota = 0;
    var selected = {};

    mnWizardStep2Service.setSelected = function (selected) {
      selected = selected;
      sampleBucketsRAMQuota = _.reduce(selected, function (memo, num) {
        return memo + Number(num);
      }, 0);
    };

    mnWizardStep2Service.getSampleBucketsRAMQuota = function () {
      return sampleBucketsRAMQuota;
    };

    mnWizardStep2Service.isSomeBucketSelected = function () {
      return !_.isEmpty(selected);
    }

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
        data: JSON.stringify(_.keys(selected))
      });
    };

    return mnWizardStep2Service;
  });