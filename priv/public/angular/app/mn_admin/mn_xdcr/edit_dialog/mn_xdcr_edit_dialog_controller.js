angular.module('mnXDCR').controller('mnXDCREditDialogController',
  function ($scope, $modalInstance, mnPromiseHelper, mnXDCRService, currentSettings, globalSettings, id) {
    $scope.settings = _.extend({}, globalSettings.data, currentSettings.data);
    $scope.createReplication = function () {
      var promise = mnXDCRService.saveReplicationSettings(id, mnXDCRService.removeExcessSettings($scope.settings));
      mnPromiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    };
  });
