angular.module('mnAdminSettingsClusterService').factory('mnAdminSettingsClusterService',
  function ($http, mnAdminService, mnAdminServersService) {
    var mnAdminSettingsClusterService = {};
    mnAdminSettingsClusterService.model = {};

    var service = mnAdminSettingsClusterService;
    var model = service.model;

    var getInMegs = function (value) {
      return Math.floor(value / Math.Mi);
    };
    var setCertificate = function (certificate) {
      model.certificate = certificate;
    };
    var setError = function (errors) {
      model.errors = errors.errors;
    };

    service.getAndSetDefaultCertificate = function () {
      return $http({
        method: 'GET',
        url: '/pools/default/certificate'
      }).success(setCertificate);
    };
    service.regenerateCertificate = function () {
      return $http({
        method: 'POST',
        url: '/controller/regenerateCertificate',
        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
      }).success(setCertificate);
    };
    service.saveVisualInternalSettings = function (settings, justValidate) {
      var params = {
        method: 'POST',
        url: '/internalSettings/visual',
        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'},
        data: _.serializeData(settings)
      };

      if (!!justValidate) {
        params.url += '?just_validate=1';
        return $http(params).success(setError).error(setError);
      } else {
        return $http(params).error(setError).success(mnAdminService.runDefaultPoolsDetailsLoop);
      }
    };


    service.initializeMnAdminSettingsClusterScope = function ($scope) {

      $scope.$watch('memoryQuota', function () {
        service.saveVisualInternalSettings({
          memoryQuota: $scope.memoryQuota,
          tabName: $scope.tabName
        }, "justValidate");
      }); //live validation of memoryQuota

      $scope.$watch(function () {
        if (mnAdminService.model.details && mnAdminServersService.model.nodes) {
          return mnAdminService.model.details.storageTotals.ram.total /
                 mnAdminServersService.model.nodes.onlyActive.length;
        }
      }, function (ramTotalPerActiveNode) {
        model.totalRam = getInMegs(ramTotalPerActiveNode);
        model.maxRamMegs = Math.max(
          getInMegs(ramTotalPerActiveNode) - 1024,
          Math.floor(ramTotalPerActiveNode * 4 / (5 * Math.Mi))
        );
      });

      var usubscribeGetMemoryQuota = $scope.$watch(function () {
        if (mnAdminService.model.details) {
          return getInMegs(mnAdminService.model.details.storageTotals.ram.quotaTotalPerNode);
        }
      }, function (memoryQuota) {
        if (!memoryQuota) {
          return;
        }
        usubscribeGetMemoryQuota();
        $scope.memoryQuota = memoryQuota;
      });

      //Get tabName only once
      var usubscribeGetVisualSettings = $scope.$watch(function () {
        if (mnAdminService.model.details) {
          return mnAdminService.model.details.visualSettingsUri;
        }
      }, function (url) {
        if (!url) {
          return;
        }

        usubscribeGetVisualSettings();

        $http({method: 'GET', url: url}).success(function (visualInternalSettings) {
          $scope.tabName = visualInternalSettings.tabName;
        });
      });
    };

    return service;
});