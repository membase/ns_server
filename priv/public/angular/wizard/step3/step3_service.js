angular.module('wizard.step3.service', [])
  .factory('wizard.step3.service',
    ['$http', 'wizard.step2.service', function ($http, step2Service) {

      var scope = {};
      scope.model = {};

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

      scope.tryToGetDefaultBucketInfo = function tryToGetDefaultBucketInfo(justValidate) {
        return $http({method: 'GET', url: defaultBucketUrl});
      };

      scope.getBucketConf = function getBucketConf(data) {
        return _.extend(data ? _.pick(data, _.keys(defaultBucketConf)) : defaultBucketConf, {
          otherBucketsRamQuotaMB: _.bytesToMB(step2Service.model.sampleBucketsRAMQuota)
        });
      };

      scope.postBuckets = function postBuckets(justValidate) {
        var request = {
          method: 'POST',
          url: scope.model.isDefaultBucketPresented ? defaultBucketUrl : '/pools/default/buckets',
          data: _.serializeData(scope.model.bucketConf),
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

      return scope;
    }]);