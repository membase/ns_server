angular.module('mnWizardStep5Service').factory('mnWizardStep5Service',
  function ($http) {
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

    mnWizardStep5Service.postAuth = function () {
      var cloned = _.clone(mnWizardStep5Service.model.user);

      delete cloned.verifyPassword;
      cloned.port = "SAME";

      return $http({
        method: 'POST',
        url: '/settings/web',
        data: _.serializeData(cloned),
        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
      });
    };

    return mnWizardStep5Service;
  });