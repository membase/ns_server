angular.module('mnWizardStep5Service', [
  'mnHttp'
]).factory('mnWizardStep5Service',
  function (mnHttp) {
    var mnWizardStep5Service = {};

    mnWizardStep5Service.postAuth = function (user) {
      var data = _.clone(user);
      delete data.verifyPassword;
      data.port = "SAME";

      return mnHttp({
        method: 'POST',
        url: '/settings/web',
        data: data
      });
    };

    return mnWizardStep5Service;
  });