angular.module('mnWizardStep4Service').factory('mnWizardStep4Service',
  function (mnHttpService) {

    var mnWizardStep4Service = {};
    mnWizardStep4Service.model = {};
    mnWizardStep4Service.model.sendStats = true;
    mnWizardStep4Service.model.register = {
      version: '',
      email: '',
      firstname: '',
      lastname: '',
      company: '',
      agree: true
    };

    mnWizardStep4Service.postEmail = mnHttpService({
      method: 'JSONP',
      url: 'http://ph.couchbase.net/email',
      params: {
        callback: 'JSON_CALLBACK'
      }
    });


    mnWizardStep4Service.postStats = mnHttpService({
      method: 'POST',
      url: '/settings/stats'
    });

    return mnWizardStep4Service;
  });