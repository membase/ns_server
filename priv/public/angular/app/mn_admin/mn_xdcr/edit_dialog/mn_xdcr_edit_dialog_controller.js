angular.module('mnXDCR').controller('mnXDCREditDialogController',
  function ($scope, $modalInstance, mnHelper, mnXDCRService, currentSettings, globalSettings, id) {
    $scope.settings = _.extend({}, globalSettings.data, currentSettings.data);
    $scope.createReplication = function () {
      var promise = mnXDCRService.saveReplicationSettings(id, mnXDCRService.removeExcessSettings($scope.settings));
      mnHelper
        .promiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    };
  });
