angular.module('mnServers').controller('mnServersAddDialogController',
  function ($scope, mnServersService, $modalInstance, mnHelper, groups) {
    reset();
    $scope.addNodeConfig = {
      services: {
        model: {
          kv: true,
          index: true,
          n1ql: true
        }
      },
      credentials: {
        hostname: '',
        user: 'Administrator',
        password: ''
      }
    };

    $scope.cancel = function () {
      $modalInstance.dismiss('cancel');
    };

    function reset() {
      $scope.focusMe = true;
    }

    $scope.isGroupsAvailable = !!groups;

    if ($scope.isGroupsAvailable) {
      $scope.addNodeConfig.selectedGroup = groups.groups[0];
      $scope.groups = groups.groups;
    }

    $scope.onSubmit = function (form) {
      if ($scope.viewLoading) {
        return;
      }

      var servicesList = mnHelper.checkboxesToList($scope.addNodeConfig.services.model);

      form.$setValidity('services', !!servicesList.length);

      if (form.$invalid) {
        return reset();
      }

      var promise = mnServersService.addServer($scope.addNodeConfig.selectedGroup, $scope.addNodeConfig.credentials, servicesList);
      mnHelper
        .promiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    };
  });
