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
    mnSettingsClusterService.saveClusterSettings = function (data) {
      return mnHttp({
        method: 'POST',
        url: '/pools/default',
        data: data
      });
    };
    mnSettingsClusterService.clusterSettingsValidation = function (data) {
      return mnHttp({
        method: 'POST',
        params: {
          just_validate: 1,
        },
        data: data,
        url: '/pools/default'
      });
    };

    return mnSettingsClusterService;
});