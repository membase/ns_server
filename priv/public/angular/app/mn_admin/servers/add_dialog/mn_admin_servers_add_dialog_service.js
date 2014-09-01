angular.module('mnAdminServersAddDialogService').factory('mnAdminServersAddDialogService',
  function ($http) {
    var mnAdminServersAddDialogService = {};
    var initialNewServer = {
      hostname: '',
      user: 'Administrator',
      password: ''
    };
    mnAdminServersAddDialogService.model = {
      selectedGroup: undefined
    };
    mnAdminServersAddDialogService.model.newServer = {};
    mnAdminServersAddDialogService.resetModel = function () {
      mnAdminServersAddDialogService.model.newServer = _.clone(initialNewServer);
    };
    mnAdminServersAddDialogService.addServer = function (url) {
      var selectedGroup = mnAdminServersAddDialogService.model.selectedGroup;

      return $http({
        method: 'POST',
        url: (selectedGroup && selectedGroup.addNodeURI) || url,
        data: _.serializeData(mnAdminServersAddDialogService.model.newServer),
        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
      });
    };

    return mnAdminServersAddDialogService;

  });
