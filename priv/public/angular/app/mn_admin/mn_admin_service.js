angular.module('mnAdminService').factory('mnAdminService',
  function ($http, $q, $timeout, $state, mnHttpService, mnAuthService, mnAdminTasksService, mnAdminServersListItemService) {
    var mnAdminService = {};
    mnAdminService.model = {};

    function prepareNodesModel() {
      var hostnameToGroup = (mnAdminService.model.isGroupsAvailable && mnAdminService.model.hostnameToGroup) || {};

      var nodes = _.map(mnAdminService.model.details.nodes, function (n) {
        n = _.clone(n);
        var group = hostnameToGroup[n.hostname];
        if (group) {
          n.group = group.name;
        }
        return n;
      });

      var stillActualEject = [];

      _.each(mnAdminServersListItemService.model.pendingEject, function (node) {
        var original = _.detect(nodes, function (n) {
          return n.otpNode == node.otpNode;
        });
        if (!original || original.clusterMembership === 'inactiveAdded') {
          return;
        }
        stillActualEject.push(original);
        original.pendingEject = true;
      });

      mnAdminServersListItemService.model.pendingEject = stillActualEject;

      var rv = {};

      rv.allNodes = nodes;

      rv.failedOver = _.filter(nodes, function (node) {
        return node.clusterMembership === 'inactiveFailed';
      });
      rv.onlyActive = _.filter(nodes, function (node) {
        return node.clusterMembership === 'active';
      });
      rv.active = rv.failedOver.concat(rv.onlyActive);
      rv.down = _.filter(nodes, function (node) {
        return node.status !== 'healthy';
      });
      rv.pending = _.filter(nodes, function (node) {
        return node.clusterMembership !== 'active';
      }).concat(mnAdminServersListItemService.model.pendingEject);
      rv.reallyActive = _.filter(rv.onlyActive, function (node) {
        return !node.pendingEject
      });
      rv.unhealthyActive = _.detect(rv.reallyActive, function (node) {
        return node.status === 'unhealthy';
      });
      mnAdminService.model.nodes = rv;
    };

    function prepareGroupsModel(data) {
      mnAdminService.model.groups = data.groups;

      var hostnameToGroup = {};
      _.each(data.groups, function (group) {
        _.each(group.nodes, function (node) {
          hostnameToGroup[node.hostname] = group;
        });
      });

      mnAdminService.model.hostnameToGroup = hostnameToGroup;
    }

    mnAdminService.getGroups = _.compose(mnHttpService({
      method: 'GET',
      url: '/pools/default/serverGroups',
      success: [prepareGroupsModel]
    }), function (url) {
      return {url: url};
    });

    var defaultPoolsDetailsRequest = mnHttpService({
      method: 'GET',
      responseType: 'json',
      timeout: 30000,
      success: [defaultPoolsDetailsLoop]
    });

    function preparePoolDetails(details) {
      if (!details) {
        return;
      }
      mnAdminService.model.isEnterprise = details.isEnterprise;
      mnAdminService.model.details = details;
      mnAdminService.model.isGroupsAvailable = !!(mnAdminService.model.isEnterprise && mnAdminService.model.details.serverGroupsUri);
      prepareNodesModel();
      mnAdminService.model.ramTotalPerActiveNode = mnAdminService.model.details.storageTotals.ram.total / mnAdminService.model.nodes.onlyActive.length;
    }

    function defaultPoolsDetailsLoop(details) {
      var params = {};
      params.url = mnAuthService.model.defaultPoolUri;
      params.params = {waitChange: getWaitChangeOfPoolsDetailsLoop()};
      details && details.etag && (params.params.etag = details.etag);

      return defaultPoolsDetailsRequest(params).success(preparePoolDetails);
    }

    mnAdminService.runDefaultPoolsDetailsLoop = defaultPoolsDetailsLoop;

    function getWaitChangeOfPoolsDetailsLoop() {
      return $state.current.name === 'admin.overview' ||
             $state.current.name === 'admin.manage_servers' ? 3000 : 20000;
    }

    mnAdminService.initializeWatchers = function ($scope) {
      $scope.$on('$destroy', mnAdminTasksService.stopTasksLoop);
      $scope.$on('$destroy', defaultPoolsDetailsRequest.cancel);

      $scope.$watch(getWaitChangeOfPoolsDetailsLoop, mnAdminService.runDefaultPoolsDetailsLoop);

      $scope.$watch(function () {
        return {
          hostnameToGroup: mnAdminService.model.hostnameToGroup,
          nodes: mnAdminService.model.details.nodes,
          pendingEjectLength: mnAdminServersListItemService.model.pendingEject.length
        };
      }, prepareNodesModel, true);

      $scope.$watch(function () {
        return {url: mnAdminService.model.details.tasks.uri};
      }, mnAdminTasksService.runTasksLoop, true);

      $scope.$watch(function () {
        return mnAdminService.model.details.serverGroupsUri;
      }, mnAdminService.getGroups);
    };

    return mnAdminService;
  });
