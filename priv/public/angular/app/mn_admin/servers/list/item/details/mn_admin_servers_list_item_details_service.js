angular.module('mnAdminServersListItemDetailsService').factory('mnAdminServersListItemDetailsService',
  function (mnHttpService) {
    var mnAdminServersListItemDetailsService = {};

    mnAdminServersListItemDetailsService.getNodeDetails = _.compose(mnHttpService({
      method: 'GET'
    }), function (node) {
      return {url: '/nodes/' + encodeURIComponent(node.otpNode)};
    });

    return mnAdminServersListItemDetailsService;
  });
