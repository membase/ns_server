angular.module('mnServers').controller('mnServersAddDialogController',
  function ($scope, $modal, mnServersService, $modalInstance, mnHelper, mnPromiseHelper, groups, mnPoolDefault, mnMemoryQuotaService) {
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

      promise = mnPromiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .closeOnSuccess()
        .getPromise()
        .then(function () {
          return mnPoolDefault.getFresh().then(function (poolsDefault) {
            if (mnMemoryQuotaService.isOnlyOneNodeWithService(poolsDefault.nodes, $scope.addNodeConfig.services.model, 'index')) {
              return $modal.open({
                templateUrl: 'mn_admin/mn_servers/memory_quota_dialog/memory_quota_dialog.html',
                controller: 'mnServersMemoryQuotaDialogController',
                resolve: {
                  memoryQuotaConfig: function (mnMemoryQuotaService) {
                    return mnMemoryQuotaService.memoryQuotaConfig($scope.addNodeConfig.services.model.kv)
                  }
                }
              }).result;
            }
          });
        });

      mnPromiseHelper($scope, promise)
        .reloadState();
    };
  });
