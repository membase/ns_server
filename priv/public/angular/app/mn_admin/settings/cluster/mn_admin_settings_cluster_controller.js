angular.module('mnAdminSettingsCluster').controller('mnAdminSettingsClusterController',
  function ($scope, mnAdminSettingsClusterService) {
    $scope.model = mnAdminSettingsClusterService.model;
    $scope.focusMe = true;

    var clusterCertificateSpinnerCtrl = function (state) {
      $scope.regenerateCertificateInprogress = state;
    };

    var settingsClusterLoadedCtrl = function (state) {
      $scope.settingsClusterLoaded = state;
    }

    $scope.saveVisualInternalSettings = function () {
      mnAdminSettingsClusterService.saveVisualInternalSettings({spinner: settingsClusterLoadedCtrl, data: $scope.formData});
    };
    $scope.regenerateCertificate = function () {
      mnAdminSettingsClusterService.regenerateCertificate({spinner: clusterCertificateSpinnerCtrl});
    };
    $scope.toggleCertArea = function () {
      $scope.toggleCertAreaFlag = !$scope.toggleCertAreaFlag;
    };

    mnAdminSettingsClusterService.getAndSetDefaultCertificate({spinner: clusterCertificateSpinnerCtrl});
    mnAdminSettingsClusterService.initializeMnAdminSettingsClusterScope($scope);
  });
