angular.module('mnAdminServers').controller('mnAdminServersAddDialogController',
  function ($scope, mnAdminServersAddDialogService, mnAdminGroupsService, mnAdminService, mnDialogService) {
    reset();
    $scope.mnAdminServersAddDialogServiceModel = mnAdminServersAddDialogService.model;
    var newServer = $scope.mnAdminServersAddDialogServiceModel.newServer;

    function reset() {
      $scope.viewLoading = false;
      $scope.focusMe = true;
      mnAdminServersAddDialogService.resetModel();
    }

    mnAdminServersAddDialogService.model.selectedGroup = undefined;
    $scope.$watch(function () {
      return mnAdminService.model.isGroupsAvailable && mnAdminService.model.groups[0];
    }, function (defaultGroup) {
      if (!mnAdminServersAddDialogService.model.selectedGroup) {
        mnAdminServersAddDialogService.model.selectedGroup = defaultGroup;
      }
    });

    $scope.onSubmit = function () {
      if ($scope.viewLoading) {
        return;
      }
      $scope.viewLoading = true;
      $scope.form.$setValidity('hostnameReq', !!newServer.hostname);

      if ($scope.form.$invalid) {
        return reset();
      }

      mnAdminServersAddDialogService
        .addServer(mnAdminService.model.details.controllers.addNode.uri)
        .error(function (errors) {
          $scope.formErrors = errors;
        }).success(function () {
          mnAdminService.getGroups(mnAdminService.model.details.serverGroupsUri);
          mnDialogService.removeLastOpened();
        })['finally'](reset);

    };
  });
