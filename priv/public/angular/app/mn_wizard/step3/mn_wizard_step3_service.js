angular.module('mnWizardStep3Service').factory('mnWizardStep3Service',
  function (mnHttpService, mnWizardStep2Service) {

    var mnWizardStep3Service = {};
    mnWizardStep3Service.model = {};

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

    mnWizardStep3Service.tryToGetDefaultBucketInfo = mnHttpService({
      method: 'GET',
      url: '/pools/default/buckets/default'
    });

    function getPostBucketsParams(justValidate) {
      var requestParams = {
        data: mnWizardStep3Service.model.bucketConf
      };

      if (mnWizardStep3Service.model.isDefaultBucketPresented) {
        requestParams.url = '/pools/default/buckets/default';
      }

      if (justValidate) {
        requestParams.params = {
          just_validate: 1,
          ignore_warnings: 1
        };
      }
      return requestParams;
    }

    mnWizardStep3Service.getBucketConf = function (data) {
      return _.extend(data ? _.pick(data, _.keys(defaultBucketConf)) : defaultBucketConf, {
        otherBucketsRamQuotaMB: _.bytesToMB(mnWizardStep2Service.model.sampleBucketsRAMQuota)
      });
    };

    mnWizardStep3Service.postBuckets = _.compose(mnHttpService({
      method: 'POST',
      url: '/pools/default/buckets'
    }), getPostBucketsParams);

    return mnWizardStep3Service;
  });