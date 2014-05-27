angular.module('wizard.step2.service', [])
  .factory('wizard.step2.service',
    ['$http', function ($http) {

      var scope = {};
      scope.model = {
        selected: {},
        sampleBucketsRAMQuota: 0
      };

      scope.getSampleBuckets = function getSampleBuckets() {
        return $http({
          url: '/sampleBuckets',
          method: 'GET'
        });
      }

      scope.installSampleBuckets = function installSampleBuckets() {
        return $http({
          url: '/sampleBuckets/install',
          method: 'POST',
          data: JSON.stringify(_.keys(scope.model.selected)),
          timeout: 140000
        });
      }

      return scope;
    }]);