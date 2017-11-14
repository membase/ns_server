var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnPermissions = (function () {
  "use strict";

  var bucketSpecificPermissions = [function (name, buckets) {
    var basePermissions = [
      "cluster.bucket[" + name + "].settings!write",
      "cluster.bucket[" + name + "].settings!read",
      "cluster.bucket[" + name + "].recovery!write",
      "cluster.bucket[" + name + "].recovery!read",
      "cluster.bucket[" + name + "].stats!read",
      "cluster.bucket[" + name + "]!flush",
      "cluster.bucket[" + name + "]!delete",
      "cluster.bucket[" + name + "]!compact",
      "cluster.bucket[" + name + "].xdcr!read",
      "cluster.bucket[" + name + "].xdcr!write",
      "cluster.bucket[" + name + "].xdcr!execute"
    ];
    if (name === "." || buckets.byName[name].isMembase) {
      basePermissions = basePermissions.concat([
        "cluster.bucket[" + name + "].views!read",
        "cluster.bucket[" + name + "].views!write",
        "cluster.bucket[" + name + "].views!compact"
      ]);
    }
    if (name === "." || !buckets.byName[name].isMemcached) {
      basePermissions = basePermissions.concat([
        "cluster.bucket[" + name + "].data!write",
        "cluster.bucket[" + name + "].data!read",
        "cluster.bucket[" + name + "].data.docs!read"
      ]);
    }

    return basePermissions
  }];

  var interestingPermissions = [
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
    "cluster.admin.settings!read",
    "cluster.admin.settings!write",
    "cluster.logs!read",
    "cluster.pools!write",
    "cluster.indexes!write",
    "cluster.admin.security!write",
    "cluster.samples!read",
    "cluster.nodes!read"
  ];

  interestingPermissions =
    interestingPermissions.concat(generateBucketPermissions("."));

  MnPermissionsService.annotations = [
    new ng.core.Injectable()
  ];

  MnPermissionsService.parameters = [
    ng.common.http.HttpClient,
    mn.services.MnBuckets,
    mn.services.MnAdmin
  ];

  MnPermissionsService.prototype.getAll = getAll;
  MnPermissionsService.prototype.set = set;
  MnPermissionsService.prototype.setBucketSpecific = setBucketSpecific;
  MnPermissionsService.prototype.doGet = doGet;

  return MnPermissionsService;

  function MnPermissionsService(http, mnBucketsService, mnAdminService) {
    this.http = http;
    this.stream = {};

    this.stream.url =
      mnAdminService
      .stream
      .getPoolsDefault
      .pluck("checkPermissionsURI")
      .distinctUntilChanged();

    this.stream.getBucketsPermissions =
      mnBucketsService
      .stream
      .getSuccess
      .map(function (rv) {
        return _.reduce(rv, function (acc, bucket) {
          return acc.concat(generateBucketPermissions(bucket.name, rv));
        }, []);
      })
      .combineLatest(this.stream
                     .url)
      .switchMap(this.doGet.bind(this))
      .shareReplay(1);

    this.stream.getSuccess =
      this.stream
      .url
      .map(function (url) {
        return [getAll(), url];
      })
      .switchMap(this.doGet.bind(this))
      .shareReplay(1);

    this.stream.permissionByBucketNames =
      this.stream
      .getBucketsPermissions
      .map(_.curry(_.reduce)(_, function (rv, value, key, permissions) {
        var splitKey = key.split(/bucket\[|\]/);
        var bucketPermission = splitKey[2];
        var bucketName = splitKey[1];
        if (bucketPermission) {
          rv[bucketPermission] = rv[bucketPermission] || [];
          rv[bucketPermission].push(bucketName);
        }
      }, {}));
  }

  function generateBucketPermissions(bucketName, buckets) {
    return bucketSpecificPermissions.reduce(function (acc, getChunk) {
      return acc.concat(getChunk(bucketName, buckets));
    }, []);
  }

  function getAll() {
    return _.clone(interestingPermissions);
  }

  function set(permission) {
    if (!_.contains(interestingPermissions, permission)) {
      interestingPermissions.push(permission);
    }
    return this;
  }

  function setBucketSpecific(func) {
    if (angular.isFunction(func)) {
      bucketSpecificPermissions.push(func);
    }
    return this;
  }

  function doGet(urlAndPermissions) {
    return this.http.post(urlAndPermissions[1], urlAndPermissions[0].join(','));
  }
})();
