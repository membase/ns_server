angular.module('mnAdminServersFailOverDialogService').factory('mnAdminServersFailOverDialogService',
  function (mnHttpService) {
    var mnAdminServersFailOverDialogService = {};
    mnAdminServersFailOverDialogService.model = {};
    mnAdminServersFailOverDialogService.getNodeStatuses = _.compose(mnHttpService({
      method: 'GET'
    }), function (url) {
      return {url: url};
    });

    return mnAdminServersFailOverDialogService;
  });
