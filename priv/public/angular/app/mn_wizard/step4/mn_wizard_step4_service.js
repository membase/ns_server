angular.module('mnWizardStep4Service').factory('mnWizardStep4Service',
  function (mnHttp) {
    var mnWizardStep4Service = {};

    mnWizardStep4Service.postEmail = function (register) {
      var params = _.clone(register);
      delete params.agree;
      params.callback = 'JSON_CALLBACK';

      return mnHttp({
        method: 'JSONP',
        url: 'http://ph.couchbase.net/email',
        params: params
      });
    };


    mnWizardStep4Service.postStats = function (data) {
      return mnHttp({
        method: 'POST',
        url: '/settings/stats',
        data: data
      });
    };

    return mnWizardStep4Service;
  });