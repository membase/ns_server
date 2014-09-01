angular.module('mnAdminServersFailOverDialogService').factory('mnAdminServersFailOverDialogService',
  function ($http, $q, $timeout) {
    var mnAdminServersFailOverDialogService = {};
    mnAdminServersFailOverDialogService.model = {};
    mnAdminServersFailOverDialogService.getNodeStatuses = function (url) {
      return $http({method: 'GET', url: url});
    };

    return mnAdminServersFailOverDialogService;
  });
