(function () {
  "use strict";

  angular.module('mnWizardStep5Service', [
    'mnHttp'
  ]).factory('mnWizardStep5Service', mnWizardStep5ServiceFactory);

  function mnWizardStep5ServiceFactory(mnHttp) {
    var mnWizardStep5Service = {
      postAuth: postAuth
    };

    return mnWizardStep5Service;

    function postAuth(user) {
      var data = _.clone(user);
      delete data.verifyPassword;
      data.port = "SAME";

      return mnHttp({
        method: 'POST',
        url: '/settings/web',
        data: data
      });
    }
  }
})();
