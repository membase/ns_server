angular.module('wizard.step1.joinCluster.service', [])
  .factory('wizard.step1.joinCluster.service',
    ['$http', 'wizard.step1.service',
      function ($http, step1Service) {

        var scope = {};
        var defaultClusterMember = {
          hostname: "127.0.0.1",
          user: "Administrator",
          password: ''
        };
        scope.model = {
          joinCluster: 'no',
          dynamicRamQuota: undefined,
          ramTotalSize: undefined,
          ramMaxMegs: undefined,
        };

        scope.resetClusterMember = function resetClusterMember() {
          scope.model.clusterMember = defaultClusterMember;
        };

        scope.resetClusterMember();

        scope.postMemory = function postMemory() {
          return $http({
            method: 'POST',
            url: '/pools/default',
            data: 'memoryQuota=' + scope.model.dynamicRamQuota,
            headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
          });
        };
        scope.postJoinCluster = function postJoinCluster() {
          return $http({
            method: 'POST',
            url: '/node/controller/doJoinCluster',
            data: _.serializeData(scope.model.clusterMember),
            headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
          });
        };
        scope.populateModel = function populateModel(ram) {
          if (!ram) {
            return;
          }
          var totalRAMMegs = Math.floor(ram.total / Math.Mi);
          scope.model.dynamicRamQuota = Math.floor(ram.quotaTotal / Math.Mi);
          scope.model.ramTotalSize = totalRAMMegs;
          scope.model.ramMaxMegs = Math.max(totalRAMMegs - 1024, Math.floor(ram.total * 4 / (5 * Math.Mi)));
        };

        return scope;
      }]);