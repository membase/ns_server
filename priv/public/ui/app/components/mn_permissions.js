(function () {
  "use strict";

  angular
    .module("mnPermissions", [])
    .provider("mnPermissions", mnPermissionsProvider);

  function mnPermissionsProvider() {

    this.$get = ["$http", "$timeout", "$q", "$rootScope", "mnBucketsService", mnPermissionsFacatory];
    this.set = set;

    var interestedPermissions = [
      "cluster.buckets!create",
      "cluster.nodes!write",
      "cluster.pools!read",
      "cluster.server_groups!read",
      "cluster.server_groups!write",
      "cluster.settings!read",
      "cluster.settings!write",
      "cluster.stats!read",
      "cluster.tasks!read",
      "cluster.indexes!read",
      "cluster.admin.internal!all",
      "cluster.xdcr.settings!read",
      "cluster.xdcr.settings!write",
      "cluster.xdcr.remote_clusters!read",
      "cluster.xdcr.remote_clusters!write",
      "cluster.admin.security!read",
      "cluster.admin.logs!read",
      "cluster.logs!read",
      "cluster.pools!write",
      "cluster.indexes!write",
      "cluster.admin.security!write",
      "cluster.samples!read",
      "cluster.nodes!read",
      "cluster.bucket[?].xdcr!read",
      "cluster.bucket[?].xdcr!write",
      "cluster.bucket[?].xdcr!execute",
      "cluster.bucket[?].stats!read"
    ];

    function getAll() {
      return _.clone(interestedPermissions);
    }

    function set(permission) {
      if (!_.contains(interestedPermissions, permission)) {
        interestedPermissions.push(permission);
      }
    }

    function mnPermissionsFacatory($http, $timeout, $q, $rootScope, mnBucketsService) {
      var mnPermissions = {
        clear: clear,
        set: set,
        check: check,
        export: {
          data: {},
          cluster: {},
          default: {
            all: undefined,
            membase: undefined
          }
        }
      };
      var promisePerPermission = {};
      var timeId;

      return mnPermissions;

      function generateBucketPermissions(name) {
        return [
          "cluster.bucket[" + name + "].settings!write",
          "cluster.bucket[" + name + "].data!write",
          "cluster.bucket[" + name + "].recovery!write",
          "cluster.bucket[" + name + "].settings!read",
          "cluster.bucket[" + name + "].data!read",
          "cluster.bucket[" + name + "].recovery!read",
          "cluster.bucket[" + name + "].views!read",
          "cluster.bucket[" + name + "].stats!read",
          "cluster.bucket[" + name + "]!flush",
          "cluster.bucket[" + name + "]!delete",
          "cluster.bucket[" + name + "]!compact",
          "cluster.bucket[" + name + "].views!compact"
        ];
      }

      function clear() {
        delete $rootScope.rbac;
        mnPermissions.export.cluster = {};
        mnPermissions.export.data = {};
      }

      function check() {
        return mnBucketsService.getBucketsByType().then(function (bucketsDetails) {
          var permissions = getAll();
          angular.forEach(bucketsDetails, function (bucket) {
            permissions = permissions.concat(generateBucketPermissions(bucket.name));
          });
          mnPermissions.export.default.all = bucketsDetails.byType.defaultName;
          mnPermissions.export.default.membase = bucketsDetails.byType.membase.defaultName;
          return doCheck(permissions);
        }, function (resp) {
          switch (resp.status) {
            case 403: return doCheck(getAll());
            default: return $q.reject(resp);
          }
        });
      }

      function convertIntoTree(permissions) {
        var rv = {};
        var root;
        var level;
        angular.forEach(permissions, function (value, key) {
          var levels = key.split(/[\[\]]+/);
          var regex = /[.:!]+/;
          if (levels[1]) {
            levels = _.compact(levels[0].split(regex).concat([levels[1]]).concat(levels[2].split(regex)))
          } else {
            levels = levels[0].split(regex);
          }
          var lastOne = levels.pop();
          root = rv;
          while (levels.length) {
            level = levels.shift();
            root = root[level] = root[level] || {};
          }
          root[lastOne] = value;
        });
        return rv;
      }

      function doCheck(interestedPermissions) {
        return $http({
          method: "POST",
          url: "/pools/default/checkPermissions",
          data: interestedPermissions.join(',')
        }).then(function (resp) {
          var rv = convertIntoTree(resp.data);
          mnPermissions.export.data = resp.data;
          mnPermissions.export.cluster = rv.cluster;
          return mnPermissions.export;
        });
      }
    }
  }
})();
