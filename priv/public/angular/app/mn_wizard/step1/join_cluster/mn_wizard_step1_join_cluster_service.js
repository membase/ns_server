angular.module('mnWizardStep1JoinClusterService').factory('mnWizardStep1JoinClusterService',
  function ($http, mnWizardStep1Service) {

    var mnWizardStep1JoinClusterService = {};

    var defaultClusterMember = {
      hostname: "127.0.0.1",
      user: "Administrator",
      password: ''
    };

    mnWizardStep1JoinClusterService.model = {
      joinCluster: 'no',
      dynamicRamQuota: undefined,
      ramTotalSize: undefined,
      ramMaxMegs: undefined,
    };

    mnWizardStep1JoinClusterService.resetClusterMember = function () {
      mnWizardStep1JoinClusterService.model.clusterMember = defaultClusterMember;
    };

    mnWizardStep1JoinClusterService.resetClusterMember();

    mnWizardStep1JoinClusterService.postMemory = function () {
      return $http({
        method: 'POST',
        url: '/pools/default',
        data: _.serializeData({memoryQuota: mnWizardStep1JoinClusterService.model.dynamicRamQuota}),
        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
      });
    };

    mnWizardStep1JoinClusterService.postJoinCluster = function () {
      return $http({
        method: 'POST',
        url: '/node/controller/doJoinCluster',
        data: _.serializeData(mnWizardStep1JoinClusterService.model.clusterMember),
        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
      });
    };

    mnWizardStep1JoinClusterService.populateModel = function (ram) {
      if (!ram) {
        return;
      }
      var totalRAMMegs = Math.floor(ram.total / Math.Mi);
      mnWizardStep1JoinClusterService.model.dynamicRamQuota = Math.floor(ram.quotaTotal / Math.Mi);
      mnWizardStep1JoinClusterService.model.ramTotalSize = totalRAMMegs;
      mnWizardStep1JoinClusterService.model.ramMaxMegs = Math.max(totalRAMMegs - 1024, Math.floor(ram.total * 4 / (5 * Math.Mi)));
    };

    return mnWizardStep1JoinClusterService;
  });