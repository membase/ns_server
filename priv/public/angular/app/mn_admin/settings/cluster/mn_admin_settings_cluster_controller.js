angular.module('mnAdminSettingsCluster').controller('mnAdminSettingsClusterController',
  function ($scope, mnAdminSettingsClusterService) {
    $scope.model = mnAdminSettingsClusterService.model;
    $scope.focusMe = true;

    var clusterCertificateSpinnerCtrl = function (state) {
      $scope.regenerateCertificateInprogress = state;
    };
    var clusterSettingsSpinnerCtrl = function (state) {
      $scope.settingsClusterLoaded = state;
    };

    $scope.saveVisualInternalSettings = function () {
      clusterSettingsSpinnerCtrl(true);
      mnAdminSettingsClusterService.saveVisualInternalSettings({
        memoryQuota: $scope.memoryQuota,
        tabName: $scope.tabName
      })['finally'](function () {
        clusterSettingsSpinnerCtrl(false);
      });
    };
    $scope.regenerateCertificate = function () {
      clusterCertificateSpinnerCtrl(true);
      mnAdminSettingsClusterService.regenerateCertificate()['finally'](function () {
        clusterCertificateSpinnerCtrl(false);
      });
    };
    $scope.toggleCertArea = function () {
      $scope.toggleCertAreaFlag = !$scope.toggleCertAreaFlag;
    };

    clusterCertificateSpinnerCtrl(true);
    mnAdminSettingsClusterService.getAndSetDefaultCertificate()['finally'](function () {
      clusterCertificateSpinnerCtrl(false);
    });

    mnAdminSettingsClusterService.initializeMnAdminSettingsClusterScope($scope);
  });
