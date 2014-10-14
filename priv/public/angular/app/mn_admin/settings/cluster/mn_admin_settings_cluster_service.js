angular.module('mnAdminSettingsClusterService').factory('mnAdminSettingsClusterService',
  function (mnAdminService, mnHttpService) {
    var mnAdminSettingsClusterService = {};

    mnAdminSettingsClusterService.getDefaultCertificate = mnHttpService({
      method: 'GET',
      url: '/pools/default/certificate'
    });
    mnAdminSettingsClusterService.regenerateCertificate = mnHttpService({
      method: 'POST',
      url: '/controller/regenerateCertificate'
    });
    mnAdminSettingsClusterService.getVisulaSettings = mnHttpService({
      method: 'GET',
      url: '/internalSettings/visual'
    });
    mnAdminSettingsClusterService.saveVisualInternalSettings = mnHttpService({
      method: 'POST',
      url: '/internalSettings/visual',
      success: [mnAdminService.runDefaultPoolsDetailsLoop]
    });
    mnAdminSettingsClusterService.visualInternalSettingsValidation = mnHttpService({
      method: 'POST',
      params: {
        just_validate: 1,
      },
      url: '/internalSettings/visual'
    });

    return mnAdminSettingsClusterService;
});