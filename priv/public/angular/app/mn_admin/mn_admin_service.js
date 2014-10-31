angular.module('mnAdminService').factory('mnAdminService',
  function (mnHttp) {
    var mnAdminService = {};

    mnAdminService.getGroups = function () {
      return mnHttp({
        method: 'GET',
        url: '/pools/default/serverGroups'
      }).then(function (resp) {
        return resp.data;
      })
    };

    return mnAdminService;
  });
