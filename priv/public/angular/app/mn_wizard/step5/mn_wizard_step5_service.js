angular.module('mnWizardStep5Service').factory('mnWizardStep5Service',
  function (mnHttpService) {
    var defaultUserCreds = {
      username: 'Administrator',
      password: '',
      verifyPassword: ''
    };
    var mnWizardStep5Service = {};

    mnWizardStep5Service.model = {};

    mnWizardStep5Service.resetUserCreds = function () {
      mnWizardStep5Service.model.user = defaultUserCreds;
    };

    mnWizardStep5Service.resetUserCreds();

    mnWizardStep5Service.postAuth = mnHttpService({
      method: 'POST',
      url: '/settings/web',
      data: {
        port: "SAME"
      }
    });

    return mnWizardStep5Service;
  });