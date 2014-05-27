angular.module('wizard.step1.service', [])
  .factory('wizard.step1.service',
    ['$http', function ($http) {

      var scope = {};
      scope.model = {
        nodeConfig: undefined,
        hostname: undefined
      };

      scope.getSelfConfig = function getSelfConfig() {
        return $http({method: 'GET', url: '/nodes/self', responseType: 'json'}).success(function (nodeConfig) {
          scope.model.nodeConfig = nodeConfig;
          scope.model.hostname = (nodeConfig && nodeConfig['otpNode'].split('@')[1]) || '127.0.0.1';
        });
      };

      scope.postHostname = function postHostname() {
        return $http({
          method: 'POST',
          url: '/node/controller/rename',
          data: 'hostname=' + scope.model.hostname,
          headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
        });
      };

      return scope;
    }]);