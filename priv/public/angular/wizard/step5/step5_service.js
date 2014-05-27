angular.module('wizard.step5.service', [])
  .factory('wizard.step5.service',
    ['$http', function ($http) {
      var defaultUserCreds = {
        name: 'Administrator',
        password: '',
        verifyPassword: ''
      };
      var scope = {};
      scope.model = {};

      scope.resetUserCreds = function resetUserCreds() {
        scope.model.user = defaultUserCreds;
      };

      scope.resetUserCreds();

      scope.postAuth = function postAuth() {
        return $http({
          method: 'POST',
          url: '/settings/web',
          data: 'port=SAME' +
                '&username=' + scope.model.user.name +
                '&password=' + scope.model.user.password,
          headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
        });
      };

      return scope;
    }]);