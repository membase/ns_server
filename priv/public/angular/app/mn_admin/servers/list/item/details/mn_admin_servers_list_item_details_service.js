angular.module('mnAdminServersListItemDetailsService').factory('mnAdminServersListItemDetailsService',
  function ($http) {
    var mnAdminServersListItemDetailsService = {};

    mnAdminServersListItemDetailsService.getNodeDetails = function (node) {
      return $http({url: '/nodes/' + encodeURIComponent(node.otpNode), method: 'GET'});
    };

    return mnAdminServersListItemDetailsService;
  });
