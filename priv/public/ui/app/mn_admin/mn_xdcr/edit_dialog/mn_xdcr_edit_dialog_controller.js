angular.module('mnXDCR').controller('mnXDCREditDialogController',
  function ($scope, $uibModalInstance, mnPromiseHelper, mnXDCRService, currentSettings, globalSettings, id) {
    $scope.settings = _.extend({}, globalSettings.data, currentSettings.data);
    $scope.createReplication = function () {
      var promise = mnXDCRService.saveReplicationSettings(id, mnXDCRService.removeExcessSettings($scope.settings));
      mnPromiseHelper($scope, promise, $uibModalInstance)
        .showErrorsSensitiveSpinner()
        .cancelOnScopeDestroy()
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    };
  });
