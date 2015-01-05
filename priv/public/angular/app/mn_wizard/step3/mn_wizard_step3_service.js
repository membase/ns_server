angular.module('mnWizardStep3Service').factory('mnWizardStep3Service',
  function (mnHttp, mnWizardStep2Service, mnWizardStep1Service, mnBytesToMBFilter, bucketsFormConfiguration) {

    var mnWizardStep3Service = {};

    mnWizardStep3Service.getWizardBucketConf = function () {
      return mnHttp({
        method: 'GET',
        url: '/pools/default/buckets/default'
      }).then(function (resp) {
        var data = resp.data;
        var bucketConf = _.pick(data, _.keys( _.clone(bucketsFormConfiguration)));
        bucketConf.ramQuotaMB = mnBytesToMBFilter(resp.data.quota.rawRAM);
        bucketConf.uri = '/pools/default/buckets/default';
        return bucketConf;
      }, function () {
        var bucketConf = _.clone(bucketsFormConfiguration);
        bucketConf.name = 'default';
        bucketConf.isNew = true;
        bucketConf.ramQuotaMB =  mnWizardStep1Service.getDynamicRamQuota() - mnBytesToMBFilter(mnWizardStep2Service.getSampleBucketsRAMQuota())
        return bucketConf
      }).then(function (bucketConf) {
        bucketConf.otherBucketsRamQuotaMB = mnBytesToMBFilter(mnWizardStep2Service.getSampleBucketsRAMQuota());
        bucketConf.isWizard = true;
        return bucketConf;
      })
    };

    mnWizardStep3Service.postBuckets = function (data) {
      return mnHttp({
        data: data,
        method: 'POST',
        url: data.uri
      });
    };

    return mnWizardStep3Service;
  });