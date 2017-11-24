var mn = mn || {};
mn.pipes = mn.pipes || {};
mn.pipes.MnParseVersion =
  (function () {
    "use strict";

    MnParseVersionPipe.annotations = [
      new ng.core.Pipe({
        name: "mnParseVersion"
      })
    ];

    MnParseVersionPipe.prototype.transform = transform;

    return MnParseVersionPipe;

    function MnParseVersionPipe() {
    }

    function transform(str) {
      if (!str) {
        return;
      }
      // Expected string format:
      //   {release version}-{build #}-{Release type or SHA}-{enterprise / community}
      // Example: "1.8.0-9-ga083a1e-enterprise"
      var a = str.split(/[-_]/);
      if (a.length === 3) {
        // Example: "1.8.0-9-enterprise"
        //   {release version}-{build #}-{enterprise / community}
        a.splice(2, 0, undefined);
      }
      a[0] = (a[0].match(/[0-9]+\.[0-9]+\.[0-9]+/) || ["0.0.0"])[0];
      a[1] = a[1] || "0";
      // a[2] = a[2] || "unknown";
      // We append the build # to the release version when we display in the UI so that
      // customers think of the build # as a descriptive piece of the version they're
      // running (which in the case of maintenance packs and one-off's, it is.)
      a[3] = (a[3] && (a[3].substr(0, 1).toUpperCase() + a[3].substr(1))) || "DEV";
      return a; // Example result: ["1.8.0-9", "9", "ga083a1e", "Enterprise"]
    }
  })();

var mn = mn || {};
mn.pipes = mn.pipes || {};
mn.pipes.MnPrettyVersion =
  (function () {
    "use strict";

    MnPrettyVersionPipe.annotations = [
      new ng.core.Pipe({
        name: "mnPrettyVersion"
      })
    ];

    MnPrettyVersionPipe.parameters = [
      mn.pipes.MnParseVersion
    ];

    MnPrettyVersionPipe.prototype.transform = transform;

    return MnPrettyVersionPipe;

    function MnPrettyVersionPipe(mnParseVersion) {
      this.mnParseVersion = mnParseVersion;
    }

    function transform(str, full) {
      if (!str) {
        return;
      }
      var a = this.mnParseVersion.transform(str);
      // Example default result: "Enterprise Edition 1.8.0-7  build 7"
      // Example full result: "Enterprise Edition 1.8.0-7  build 7-g35c9cdd"
      var suffix = "";
      if (full && a[2]) {
        suffix = '-' + a[2];
      }
      return [a[3], "Edition", a[0], "build",  a[1] + suffix].join(' ');
    }
  })();


var mn = mn || {};
mn.pipes = mn.pipes || {};
mn.pipes.MnFormatProgressMessage =
  (function () {
    "use strict";

    function addNodeCount(perNode) {
      var serversCount = (_.keys(perNode) || []).length;
      return serversCount + " " + (serversCount === 1 ? 'node' : 'nodes');
    }

    MnFormatProgressMessage.annotations = [
      new ng.core.Pipe({
        name: "mnFormatProgressMessage"
      })
    ];

    MnFormatProgressMessage.prototype.transform = transform;

    return MnFormatProgressMessage;

    function MnFormatProgressMessage() {
    }

    function transform(task) {
      switch (task.type) {
      case "indexer":
        return "building view index " + task.bucket + "/" + task.designDocument;
      case "global_indexes":
        return "building index " + task.index  + " on bucket " + task.bucket;
      case "view_compaction":
        return "compacting view index " + task.bucket + "/" + task.designDocument;
      case "bucket_compaction":
        return "compacting bucket " + task.bucket;
      case "loadingSampleBucket":
        return "loading sample: " + task.bucket;
      case "orphanBucket":
        return "orphan bucket: " + task.bucket;
      case "clusterLogsCollection":
        return "collecting logs from " + addNodeCount(task.perNode);
      case "rebalance":
        var serversCount = (_.keys(task.perNode) || []).length;
        return (task.subtype == 'gracefulFailover') ?
          "failing over 1 node" :
          ("rebalancing " + addNodeCount(task.perNode));
      }
    }
  })();

var mn = mn || {};
mn.pipes = mn.pipes || {};
mn.pipes.MnFormatStorageModeError =
  (function () {
    "use strict";

    MnFormatStorageModeError.annotations = [
      new ng.core.Pipe({
        name: "mnFormatStorageModeError"
      })
    ];

    MnFormatStorageModeError.prototype.transform = transform;

    return MnFormatStorageModeError;

    function MnFormatStorageModeError() {
    }

    function transform(error) {
      if (!error) {
        return;
      }
      var errorCode =
          error.indexOf("Storage mode cannot be set to") > -1 ? 1 :
          error.indexOf("storageMode must be one of") > -1 ? 2 :
          0;
      switch (errorCode) {
      case 1:
        return "please choose another index storage mode";
      case 2:
        return "please choose an index storage mode";
      default:
        return error;
      }
    }
  })();

var mn = mn || {};
mn.modules = mn.modules || {};
mn.modules.MnPipesModule =
  (function () {
    "use strict";

    MnPipesModule.annotations = [
      new ng.core.NgModule({
        declarations: [
          mn.pipes.MnFormatStorageModeError,
          mn.pipes.MnParseVersion,
          mn.pipes.MnPrettyVersion,
          mn.pipes.MnFormatProgressMessage
        ],
        exports: [
          mn.pipes.MnFormatStorageModeError,
          mn.pipes.MnParseVersion,
          mn.pipes.MnPrettyVersion,
          mn.pipes.MnFormatProgressMessage
        ],
        imports: [],
        providers: [
          mn.pipes.MnParseVersion,
          mn.pipes.MnPrettyVersion
        ]
      })
    ];

    return MnPipesModule;

    function MnPipesModule() {
    }
  })();
