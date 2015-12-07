(function () {
  "use strict";

  angular.module('mnWizardStep5Service', [
  ]).factory('mnWizardStep5Service', mnWizardStep5ServiceFactory);

  function mnWizardStep5ServiceFactory($http) {
    var mnWizardStep5Service = {
      postAuth: postAuth
    };

    return mnWizardStep5Service;

    function postAuth(user) {
      var data = _.clone(user);
      delete data.verifyPassword;
      data.port = "SAME";

      return $http({
        method: 'POST',
        url: '/settings/web',
        data: data
      });
    }
  }
})();
