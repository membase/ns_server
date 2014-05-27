angular.module('wizard.step3.service', [])
  .factory('wizard.step3.service',
    ['$http', 'wizard.step2.service', function ($http, step2Service) {

      var scope = {};
      scope.model = {};
      scope.model.bucketConf = {
        bucketType: 'membase',
        evictionPolicy: 'valueOnly',
        replicaNumber: "1",
        replicaIndex: "0",
        threadsNumber: "8",
        flushEnabled: "0",
        ramQuotaMB: "0"
      };

      scope.postBuckets = function postBuckets(justValidate) {
        var request = {
          method: 'POST',
          url: '/pools/default/buckets',
          data: 'authType=sasl' + '&name=default' + '&saslPassword=' +
                '&bucketType=' + scope.model.bucketConf.bucketType +
                '&evictionPolicy=' + scope.model.bucketConf.evictionPolicy +
                '&replicaNumber=' + scope.model.bucketConf.replicaNumber +
                '&threadsNumber=' + scope.model.bucketConf.threadsNumber +
                '&ramQuotaMB=' + scope.model.bucketConf.ramQuotaMB +
                '&flushEnabled=' + scope.model.bucketConf.flushEnabled +
                '&otherBucketsRamQuotaMB=' + _.bytesToMB(step2Service.model.sampleBucketsRAMQuota),
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