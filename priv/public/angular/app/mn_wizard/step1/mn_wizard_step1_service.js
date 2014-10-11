angular.module('mnWizardStep1Service').factory('mnWizardStep1Service',
  function (mnHttpService) {

    var mnWizardStep1Service = {};

    mnWizardStep1Service.model = {
      nodeConfig: undefined,
      hostname: undefined
    };

    mnWizardStep1Service.getSelfConfig = mnHttpService({
      method: 'GET',
      url: '/nodes/self',
      responseType: 'json',
      success: [function (nodeConfig) {
        mnWizardStep1Service.model.nodeConfig = nodeConfig;
        mnWizardStep1Service.model.hostname = (nodeConfig && nodeConfig['otpNode'].split('@')[1]) || '127.0.0.1';
      }]
    });

    mnWizardStep1Service.postHostname = mnHttpService({
      method: 'POST',
      url: '/node/controller/rename'
    });

    return mnWizardStep1Service;
  });