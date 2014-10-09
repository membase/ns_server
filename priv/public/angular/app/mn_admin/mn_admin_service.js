angular.module('mnAdminService').factory('mnAdminService',
  function ($http, $q, $timeout, $state, mnAuthService, mnAdminTasksService, mnAdminServersListItemService) {
    var canceler;
    var timeout;
    var mnAdminService = {};
    mnAdminService.model = {};

    function stopDefaultPoolsDetailsLoop() {
      canceler && canceler.resolve();
    }

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

    function preparePoolDetails(details) {
      if (!details) {
        return;
      }
      mnAdminService.model.isEnterprise = details.isEnterprise;
      mnAdminService.model.details = details;
      mnAdminService.model.isGroupsAvailable = !!(mnAdminService.model.isEnterprise && mnAdminService.model.details.serverGroupsUri);
      prepareNodesModel();
      mnAdminService.runDefaultPoolsDetailsLoop(details);
    }

    mnAdminService.getGroups = function (url) {
      return $http({method: 'GET', url: url || '/pools/default/serverGroups'}).success(prepareGroupsModel);
    };

    mnAdminService.runDefaultPoolsDetailsLoop = function (next) {
      stopDefaultPoolsDetailsLoop();

      if (!(mnAuthService.model.defaultPoolUri && mnAuthService.model.isAuth)) {
        return;
      }

      var params = {
        url: mnAuthService.model.defaultPoolUri,
        params: {waitChange: getWaitChangeOfPoolsDetailsLoop()}
      };

      canceler = $q.defer();
      params.timeout = canceler.promise;
      params.method = 'GET';
      params.responseType = 'json';

      if (next && next.etag) {
        timeout && $timeout.cancel(timeout);
        timeout = $timeout(canceler.resolve, 30000); //TODO: add some behaviour for this case
        params.params.etag = next.etag;
      }

      return $http(params).success(preparePoolDetails);
    };

    function getWaitChangeOfPoolsDetailsLoop() {
      return $state.current.name === 'admin.overview' ||
             $state.current.name === 'admin.manage_servers' ? 3000 : 20000;
    }

    mnAdminService.initializeWatchers = function ($scope) {
      $scope.$on('$destroy', mnAdminTasksService.stopTasksLoopfunction);
      $scope.$on('$destroy', stopDefaultPoolsDetailsLoop);

      $scope.$watch(getWaitChangeOfPoolsDetailsLoop, mnAdminService.runDefaultPoolsDetailsLoop);

      $scope.$watch(function () {
        return {
          hostnameToGroup: mnAdminService.model.hostnameToGroup,
          nodes: mnAdminService.model.details.nodes,
          pendingEjectLength: mnAdminServersListItemService.model.pendingEject.length
        };
      }, prepareNodesModel, true);

      $scope.$watch(function () {
        return mnAdminService.model.details.tasks.uri;
      }, mnAdminTasksService.runTasksLoop);

      $scope.$watch(function () {
        return mnAdminService.model.details.serverGroupsUri;
      }, mnAdminService.getGroups);
    };

    return mnAdminService;
  });
