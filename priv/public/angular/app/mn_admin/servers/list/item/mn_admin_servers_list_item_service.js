angular.module('mnAdminServersListItemService').factory('mnAdminServersListItemService',
  function ($http) {
    var mnAdminServersListItemService = {};

    mnAdminServersListItemService.model = {};

    mnAdminServersListItemService.model.pendingEject = [];

    mnAdminServersListItemService.addToPendingEject = function (node) {
      mnAdminServersListItemService.model.pendingEject.push(node);
    };
    mnAdminServersListItemService.removeFromPendingEject = function (node) {
      node.pendingEject = false;
      _.remove(mnAdminServersListItemService.model.pendingEject, {'hostname': node.hostname});
    };

    return mnAdminServersListItemService;
  });
