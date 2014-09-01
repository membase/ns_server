angular.module('mnAdmin').controller('mnAdminController',
  function ($scope, $state, $location, mnAuthService, mnAdminService, mnAdminServersService, mnAdminTasksService, mnAdminGroupsService, mnAdminServersListItemService) {
    $scope.$state = $state;
    $scope.$location = $location;
    $scope._ = _;
    $scope.Math = Math;
    $scope.logout = mnAuthService.manualLogout;

    $scope.mnAdminServiceModel = mnAdminService.model;
    $scope.mnAdminGroupsServiceModel = mnAdminGroupsService.model;
    $scope.mnAdminServersServiceModel = mnAdminServersService.model;
    $scope.mnAdminTasksServiceModel = mnAdminTasksService.model;

    $scope.$on('$destroy', function () {
      mnAdminTasksService.stopTasksLoop();
      mnAdminService.stopDefaultPoolsDetailsLoop();
    });

    mnAdminService.runDefaultPoolsDetailsLoop();

    $scope.$watch(mnAdminService.waitChangeOfPoolsDetailsLoop, mnAdminService.runDefaultPoolsDetailsLoop);

    $scope.$watch('mnAdminServiceModel.details.tasks.uri', mnAdminTasksService.runTasksLoop);

    $scope.$watch('mnAdminServiceModel.details.serverGroupsUri', mnAdminGroupsService.getGroups);

    $scope.$watch(function () {
      if (mnAdminService.model.details) {
        return {
          isGroupsAvailable: mnAdminGroupsService.model.isGroupsAvailable,
          hostnameToGroup: mnAdminGroupsService.model.hostnameToGroup,
          nodes: mnAdminService.model.details.nodes,
          pendingEjectLength: mnAdminServersListItemService.model.pendingEject.length
        };
      }
    }, function (deps) {
      if (!deps) {
        return;
      }
      deps.pendingEject = mnAdminServersListItemService.model.pendingEject;
      mnAdminServersService.populateNodesModel(deps);
    }, true);

    $scope.$watch(function () {
      return !!(mnAuthService.model.isEnterprise &&
             mnAdminService.model.details &&
             mnAdminService.model.details.serverGroupsUri);
    }, mnAdminGroupsService.setIsGroupsAvailable);

  });