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
        var cloned = _.clone(scope.model.register);

        delete cloned.agree;
        cloned.callback = 'JSON_CALLBACK';

        return $http({
          method: 'JSONP',
          url: 'http://ph.couchbase.net/email?' + _.serializeData(cloned)
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