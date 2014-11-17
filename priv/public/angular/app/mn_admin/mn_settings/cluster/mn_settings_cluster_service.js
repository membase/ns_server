angular.module('mnSettingsClusterService').factory('mnSettingsClusterService',
  function (mnHttp) {
    var mnSettingsClusterService = {};


    mnSettingsClusterService.getDefaultCertificate = function () {
      return mnHttp({
        method: 'GET',
        url: '/pools/default/certificate'
      });
    };
    mnSettingsClusterService.regenerateCertificate = function () {
      return mnHttp({
        method: 'POST',
        url: '/controller/regenerateCertificate'
      });
    };
    mnSettingsClusterService.getVisulaSettings = function () {
      return mnHttp({
        method: 'GET',
        url: '/internalSettings/visual'
      });
    };
    mnSettingsClusterService.saveVisualInternalSettings = function (data) {
      return mnHttp({
        method: 'POST',
        url: '/internalSettings/visual',
        data: data
      });
    };
    mnSettingsClusterService.visualInternalSettingsValidation = function (data) {
      return mnHttp({
        method: 'POST',
        params: {
          just_validate: 1,
        },
        data: data,
        url: '/internalSettings/visual'
      });
    };

    return mnSettingsClusterService;
});