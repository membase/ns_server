(function () {
  "use strict";

  angular
    .module('mnGroupsService', [
    ])
    .factory('mnGroupsService', mnGroupsService);

  function mnGroupsService($http) {
    var mnGroupsService = {
      getGroups: getGroups,
      getGroupsState: getGroupsState,
      createGroup: createGroup,
      updateGroup: updateGroup,
      deleteGroup: deleteGroup,
      applyChanges: applyChanges
    };

    return mnGroupsService;

    function applyChanges(url, groups) {
      return $http({
        method: "PUT",
        url: url,
        data: JSON.stringify({"groups": groups})
      });
    }

    function deleteGroup(url) {
      return $http({
        method: "DELETE",
        url: url
      })
    }

    function updateGroup(groupName, url) {
      return $http({
        method: "PUT",
        url: url,
        data: {
          name: groupName
        }
      });
    }

    function createGroup(groupName) {
      return $http({
        method: "POST",
        url: "/pools/default/serverGroups",
        data: {
          name: groupName
        }
      });
    }

    function getGroupsState() {
      return mnGroupsService.getGroups();
    }

    function getGroups() {
      return $http({
        method: 'GET',
        url: '/pools/default/serverGroups'
      }).then(function (resp) {
        resp.data.currentGroups = _.cloneDeep(resp.data.groups);
        resp.data.initialGroups = _.cloneDeep(resp.data.groups);
        return resp.data;
      });
    }
  }

})();