angular.module('mnAdminGroupsService').factory('mnAdminGroupsService',
  function ($http) {
    var mnAdminGroupsService = {};
    mnAdminGroupsService.model = {};

    mnAdminGroupsService.getGroups = function (url) {
      if (!url) {
        return;
      }
      return $http({method: 'GET', url: url}).success(function (data) {
        mnAdminGroupsService.model.groups = data.groups;
        mnAdminGroupsService.model.url = data.url;

        var hostnameToGroup = {};
        _.each(data.groups, function (group) {
          _.each(group.nodes, function (node) {
            hostnameToGroup[node.hostname] = group;
          });
        });

        mnAdminGroupsService.model.hostnameToGroup = hostnameToGroup;
      });
    };

    mnAdminGroupsService.setIsGroupsAvailable = function (isGroupsAvailable) {
      mnAdminGroupsService.model.isGroupsAvailable = isGroupsAvailable;
    };

    return mnAdminGroupsService;
  });
