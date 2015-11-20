(function () {
  "use strict";

  angular.module('mnWizardStep4Service', [
    'mnHttp'
  ]).factory('mnWizardStep4Service', mnWizardStep4ServiceFactory);

  function mnWizardStep4ServiceFactory(mnHttp) {
    var mnWizardStep4Service = {
      postEmail: postEmail,
      postStats: postStats
    };

    return mnWizardStep4Service;

    function postEmail(register) {
      var params = _.clone(register);
      delete params.agree;
      params.callback = 'JSON_CALLBACK';

      return mnHttp({
        method: 'JSONP',
        url: 'http://ph.couchbase.net/email',
        params: params
      });
    }
    function postStats(data) {
      return mnHttp({
        method: 'POST',
        url: '/settings/stats',
        data: data
      });
    }
  }
})();
