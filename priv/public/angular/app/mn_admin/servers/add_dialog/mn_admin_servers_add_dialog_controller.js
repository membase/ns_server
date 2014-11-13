angular.module('mnAdminServers').controller('mnAdminServersAddDialogController',
  function ($scope, mnAdminServersService, $modalInstance, mnHelper, groups) {
    reset();
    $scope.newServer = {
      hostname: '',
      user: 'Administrator',
      password: ''
    };

    $scope.cancel = function () {
      $modalInstance.dismiss('cancel');
    };

    function reset() {
      $scope.focusMe = true;
    }

    mnAdminServersService.initializeServices($scope);

    $scope.isGroupsAvailable = !!groups;

    if ($scope.isGroupsAvailable) {
      $scope.selectedGroup = groups.groups[0];
      $scope.groups = groups.groups;
    }

    $scope.onSubmit = function (form) {
      if ($scope.viewLoading) {
        return;
      }

      form.$setValidity('services', !!mnHelper.checkboxesToList($scope.services).length);

      if (form.$invalid) {
        return reset();
      }

      var promise = mnAdminServersService.addServer($scope.selectedGroup, $scope.newServer);
      promise.then(function () {
        $modalInstance.close();
        mnAdminServersService.reloadServersState();
      });
      mnHelper.rejectReasonToScopeApplyer($scope, promise);
      mnHelper.handleSpinner($scope, promise);
    };
  });
