angular.module('mnWizardStep3Service').factory('mnWizardStep3Service',
  function (mnHttp, mnWizardStep2Service, mnWizardStep1Service, mnBytesToMBFilter, mnCountFilter, mnFormatMemSizeFilter, mnBucketsDetailsService) {

    var mnWizardStep3Service = {};

    var defaultBucketConf = {
      authType: 'sasl',
      name: 'default',
      saslPassword: '',
      bucketType: 'membase',
      evictionPolicy: 'valueOnly',
      replicaNumber: "1",
      replicaIndex: "0",
      threadsNumber: "3",
      flushEnabled: "0",
      ramQuotaMB: "0"
    };

    var bucketRequestUrl;

    mnWizardStep3Service.getBucketConf = function () {
      return mnHttp({
        method: 'GET',
        url: '/pools/default/buckets/default'
      }).then(function (resp) {
        var data = resp.data;
        var bucketConf = _.pick(data, _.keys(defaultBucketConf));
        bucketConf.isDefault = true;
        bucketConf.ramQuotaMB = mnBytesToMBFilter(resp.data.quota.rawRAM);
        return bucketConf;
      }, function () {
        var bucketConf = _.clone(defaultBucketConf);
        bucketConf.isDefault = false;
        bucketConf.ramQuotaMB = mnWizardStep1Service.getDynamicRamQuota() - mnBytesToMBFilter(mnWizardStep2Service.getSampleBucketsRAMQuota())
        return bucketConf;
      }).then(function (bucketConf) {
        bucketConf.otherBucketsRamQuotaMB = mnBytesToMBFilter(mnWizardStep2Service.getSampleBucketsRAMQuota());
        return bucketConf;
      })
    };

    function onResult(resp) {
      var result = resp.data;
      var ramSummary = result.summaries.ramSummary
      return {
        totalBucketSize: mnBytesToMBFilter(ramSummary.thisAlloc * ramSummary.nodesCount),
        nodeCount: mnCountFilter(ramSummary.nodesCount, 'node'),
        perNodeMegs: ramSummary.perNodeMegs,
        guageConfig: mnBucketsDetailsService.getBucketRamGuageConfig(ramSummary),
        errors: result.errors
      };
    }

     mnWizardStep3Service.postBuckets = function (httpParams) {
      httpParams.url = httpParams.data.isDefault ? '/pools/default/buckets/default' : '/pools/default/buckets';
      httpParams.method = 'POST';
      return mnHttp(httpParams).then(onResult, onResult);
    };

    return mnWizardStep3Service;
  });