angular.module('wizard.step4.service', [])
  .factory('wizard.step4.service',
    ['$http', function ($http) {

      var scope = {};
      scope.model = {};
      scope.model.sendStats = true;
      scope.model.register = {
        version: '',
        email: '',
        firstname: '',
        lastname: '',
        company: '',
        agree: true
      };

      scope.postEmail = function postEmail() {
        return $http({
          method: 'JSONP',
          url: 'http://ph.couchbase.net/email?callback=JSON_CALLBACK' +
               '&email=' + scope.model.register.email +
               '&firstname=' + scope.model.register.firstname +
               '&lastname=' + scope.model.register.lastname +
               '&company=' + scope.model.register.company +
               '&version=' + scope.model.register.version
        });
      };

      scope.postStats = function postStats() {
        return $http({
          method: 'POST',
          url: '/settings/stats',
          data: 'sendStats=' + scope.model.sendStats,
          headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
        });
      };

      return scope;
    }]);