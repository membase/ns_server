(function () {
  "use strict";

  angular
    .module('mnGroupsService', [
      'mnHttp'
    ])
    .factory('mnGroupsService', mnGroupsService);

  function mnGroupsService(mnHttp) {
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
      return mnHttp({
        method: "PUT",
        url: url,
        data: JSON.stringify({"groups": groups})
      });
    }

    function deleteGroup(url) {
      return mnHttp({
        method: "DELETE",
        url: url
      })
    }

    function updateGroup(groupName, url) {
      return mnHttp({
        method: "PUT",
        url: url,
        data: {
          name: groupName
        }
      });
    }

    function createGroup(groupName) {
      return mnHttp({
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
      return mnHttp({
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