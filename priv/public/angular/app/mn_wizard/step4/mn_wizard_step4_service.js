angular.module('mnWizardStep4Service').factory('mnWizardStep4Service',
  function ($http) {

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

    mnWizardStep4Service.postEmail = function () {
      var cloned = _.clone(mnWizardStep4Service.model.register);

      delete cloned.agree;
      cloned.callback = 'JSON_CALLBACK';

      return $http({
        method: 'JSONP',
        url: 'http://ph.couchbase.net/email?' + _.serializeData(cloned)
      });
    };

    mnWizardStep4Service.postStats = function () {
      return $http({
        method: 'POST',
        url: '/settings/stats',
        data: 'sendStats=' + mnWizardStep4Service.model.sendStats,
        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
      });
    };

    return mnWizardStep4Service;
  });