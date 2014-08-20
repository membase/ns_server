angular.module('mnWizardStep1Service').factory('mnWizardStep1Service',
  function ($http) {

    var mnWizardStep1Service = {};

    mnWizardStep1Service.model = {
      nodeConfig: undefined,
      hostname: undefined
    };

    mnWizardStep1Service.getSelfConfig = function () {
      return $http({method: 'GET', url: '/nodes/self', responseType: 'json'}).success(function (nodeConfig) {
        mnWizardStep1Service.model.nodeConfig = nodeConfig;
        mnWizardStep1Service.model.hostname = (nodeConfig && nodeConfig['otpNode'].split('@')[1]) || '127.0.0.1';
      });
    };

    mnWizardStep1Service.postHostname = function () {
      return $http({
        method: 'POST',
        url: '/node/controller/rename',
        data: 'hostname=' + mnWizardStep1Service.model.hostname,
        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
      });
    };

    return mnWizardStep1Service;
  });