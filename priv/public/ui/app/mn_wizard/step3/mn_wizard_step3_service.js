(function () {
  "use strict";

  angular.module('mnWizardStep3Service', [
    'mnHttp',
    'mnWizardStep1Service',
    'mnWizardStep2Service',
    'mnFilters'
  ]).factory('mnWizardStep3Service', mnWizardStep3ServiceFactory);

  function mnWizardStep3ServiceFactory(mnHttp, mnWizardStep2Service, mnWizardStep1Service, mnBytesToMBFilter, bucketsFormConfiguration) {

    var mnWizardStep3Service = {
      getWizardBucketConf: getWizardBucketConf,
      postBuckets: postBuckets
    };

    return mnWizardStep3Service;

    function getWizardBucketConf() {
      return mnHttp({
        method: 'GET',
        url: '/pools/default/buckets/default'
      }).then(function (resp) {
        var data = resp.data;
        var bucketConf = _.pick(data, _.keys( _.clone(bucketsFormConfiguration)));
        bucketConf.replicaIndex = bucketConf.replicaIndex ? 1 : 0;
        bucketConf.flushEnabled = (data.controllers !== undefined && data.controllers.flush !== undefined) ? 1 : 0;
        bucketConf.ramQuotaMB = mnBytesToMBFilter(resp.data.quota.rawRAM);
        bucketConf.uri = '/pools/default/buckets/default';
        return bucketConf;
      }, function () {
        var bucketConf = _.clone(bucketsFormConfiguration);
        bucketConf.ignoreWarnings = true;
        bucketConf.name = 'default';
        bucketConf.isNew = true;
        bucketConf.ramQuotaMB =  mnWizardStep1Service.getDynamicRamQuota() - mnBytesToMBFilter(mnWizardStep2Service.getSampleBucketsRAMQuota())
        return bucketConf
      }).then(function (bucketConf) {
        bucketConf.otherBucketsRamQuotaMB = mnBytesToMBFilter(mnWizardStep2Service.getSampleBucketsRAMQuota());
        bucketConf.isWizard = true;
        return bucketConf;
      })
    }

    function postBuckets(data) {
      return mnHttp({
        data: data,
        method: 'POST',
        url: data.uri
      });
    }
  }
})();
