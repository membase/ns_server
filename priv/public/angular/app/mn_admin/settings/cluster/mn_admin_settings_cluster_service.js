angular.module('mnAdminSettingsClusterService').factory('mnAdminSettingsClusterService',
  function (mnHttp) {
    var mnAdminSettingsClusterService = {};


    mnAdminSettingsClusterService.getDefaultCertificate = function () {
      return mnHttp({
        method: 'GET',
        url: '/pools/default/certificate'
      });
    };
    mnAdminSettingsClusterService.regenerateCertificate = function () {
      return mnHttp({
        method: 'POST',
        url: '/controller/regenerateCertificate'
      });
    };
    mnAdminSettingsClusterService.getVisulaSettings = function () {
      return mnHttp({
        method: 'GET',
        url: '/internalSettings/visual'
      });
    };
    mnAdminSettingsClusterService.saveVisualInternalSettings = function (data) {
      return mnHttp({
        method: 'POST',
        url: '/internalSettings/visual',
        data: data
      });
    };
    mnAdminSettingsClusterService.visualInternalSettingsValidation = function (data) {
      return mnHttp({
        method: 'POST',
        params: {
          just_validate: 1,
        },
        data: data,
        url: '/internalSettings/visual'
      });
    };

    return mnAdminSettingsClusterService;
});