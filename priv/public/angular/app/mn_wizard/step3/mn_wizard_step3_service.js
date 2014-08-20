angular.module('mnWizardStep3Service').factory('mnWizardStep3Service',
  function ($http, mnWizardStep2Service) {

    var mnWizardStep3Service = {};
    mnWizardStep3Service.model = {};

    var defaultBucketUrl = '/pools/default/buckets/default';
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

    mnWizardStep3Service.tryToGetDefaultBucketInfo = function (justValidate) {
      return $http({method: 'GET', url: defaultBucketUrl});
    };

    mnWizardStep3Service.getBucketConf = function (data) {
      return _.extend(data ? _.pick(data, _.keys(defaultBucketConf)) : defaultBucketConf, {
        otherBucketsRamQuotaMB: _.bytesToMB(mnWizardStep2Service.model.sampleBucketsRAMQuota)
      });
    };

    mnWizardStep3Service.postBuckets = function (justValidate) {
      var request = {
        method: 'POST',
        url: mnWizardStep3Service.model.isDefaultBucketPresented ? defaultBucketUrl : '/pools/default/buckets',
        data: _.serializeData(mnWizardStep3Service.model.bucketConf),
        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
      };

      if (justValidate) {
        request.params = {
          just_validate: 1,
          ignore_warnings: 1
        };
      }

      return $http(request);
    };

    return mnWizardStep3Service;
  });