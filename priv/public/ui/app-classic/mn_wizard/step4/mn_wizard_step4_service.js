(function () {
  "use strict";

  angular.module('mnWizardStep4Service', [
  ]).factory('mnWizardStep4Service', mnWizardStep4ServiceFactory);

  function mnWizardStep4ServiceFactory($http) {
    var mnWizardStep4Service = {
      postEmail: postEmail,
      postStats: postStats
    };

    return mnWizardStep4Service;

    function postEmail(register) {
      var params = _.clone(register);
      delete params.agree;

      return $http({
        method: 'JSONP',
        url: 'http://ph.couchbase.net/email',
        params: params
      });
    }
    function postStats(data) {
      return $http({
        method: 'POST',
        url: '/settings/stats',
        data: data
      });
    }
  }
})();
