angular.module('mnAdminServersAddDialogService').factory('mnAdminServersAddDialogService',
  function (mnHttpService) {
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

    mnAdminServersAddDialogService.addServer = _.compose(mnHttpService({
      method: 'POST'
    }), function (url) {
      var selectedGroup = mnAdminServersAddDialogService.model.selectedGroup;
      return {
        url: (selectedGroup && selectedGroup.addNodeURI) || url,
        data: mnAdminServersAddDialogService.model.newServer
      };
    });

    return mnAdminServersAddDialogService;

  });
