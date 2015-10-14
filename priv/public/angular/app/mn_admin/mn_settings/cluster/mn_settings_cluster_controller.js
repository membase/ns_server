angular.module('mnSettingsCluster', [
  'mnSettingsClusterService',
  'mnHelper',
  'mnPromiseHelper',
  'mnMemoryQuota',
  'mnSpinner'
]).controller('mnSettingsClusterController',
  function ($scope, $modal, mnSettingsClusterService, mnHelper, mnPromiseHelper, mnPoolDefault) {


    mnPromiseHelper($scope, mnSettingsClusterService.getClusterState())
      .applyToScope("state")
      .cancelOnScopeDestroy();

    $scope.mnPoolDefault = mnPoolDefault.latestValue();
    $scope.toggleCertArea = function () {
      $scope.toggleCertAreaFlag = !$scope.toggleCertAreaFlag;
    };

    if ($scope.mnPoolDefault.isROAdminCreds) {
      return;
    }

    $scope.$watch('state.memoryQuotaConfig', _.debounce(function (memoryQuotaConfig) {
      if (!memoryQuotaConfig) {
        return;
      }
      var promise = mnSettingsClusterService.postPoolsDefault($scope.state.memoryQuotaConfig, true);
      mnPromiseHelper($scope, promise)
        .catchErrorsFromSuccess("memoryQuotaErrors")
        .cancelOnScopeDestroy();
    }, 500), true);

    $scope.$watch('state.indexSettings', _.debounce(function (indexSettings) {
      if (!indexSettings) {
        return;
      }
      var promise = mnSettingsClusterService.postIndexSettings($scope.state.indexSettings, true);
      mnPromiseHelper($scope, promise)
        .catchErrorsFromSuccess("indexSettingsErrors")
        .cancelOnScopeDestroy();
    }, 500), true);

    function saveSettings() {
      var promise = mnPromiseHelper($scope, mnSettingsClusterService.postPoolsDefault($scope.state.memoryQuotaConfig, false, $scope.state.clusterName))
        .catchErrors("memoryQuotaErrors")
        .cancelOnScopeDestroy()
        .getPromise()
        .then(function () {
          return mnPromiseHelper($scope, mnSettingsClusterService.postIndexSettings($scope.state.indexSettings))
            .catchErrors("indexSettingsErrors")
            .cancelOnScopeDestroy()
            .getPromise();
        })
      mnPromiseHelper($scope, promise)
        .showSpinner('clusterSettingsLoading')
        .reloadState();
    }

    $scope.saveVisualInternalSettings = function () {
      if ($scope.clusterSettingsLoading) {
        return;
      }
      if ($scope.state.initialMemoryQuota != $scope.state.memoryQuotaConfig.indexMemoryQuota) {
        $modal.open({
          templateUrl: 'mn_admin/mn_settings/cluster/mn_settings_cluster_confirmation_dialog.html'
        }).result.then(saveSettings);
      } else {
        saveSettings();
      }
    };
    $scope.regenerateCertificate = function () {
      if ($scope.regenerateCertificateInprogress) {
        return;
      }
      mnPromiseHelper($scope, mnSettingsClusterService.regenerateCertificate())
        .onSuccess(function (certificate) {
          $scope.state.certificate = certificate;
        })
        .showSpinner('regenerateCertificateInprogress')
        .cancelOnScopeDestroy();
    };
  });
