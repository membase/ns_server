angular.module('wizard.step5.service', [])
  .factory('wizard.step5.service',
    ['$http', function ($http) {
      var defaultUserCreds = {
        username: 'Administrator',
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
        var cloned = _.clone(scope.model.user);

        delete cloned.verifyPassword;
        cloned.port = "SAME";

        return $http({
          method: 'POST',
          url: '/settings/web',
          data: _.serializeData(cloned),
          headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
        });
      };

      return scope;
    }]);