var mn = mn || {};
mn.pipes = mn.pipes || {};
mn.pipes.MnParseVersion =
  (function () {
    "use strict";

    var MnParseVersion =
        ng.core.Pipe({
          name: "mnParseVersion"
        }).Class({
          constructor: function MnParseVersionPipe() {},
          transform: function (str) {
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
        });

    return MnParseVersion;
  })();

var mn = mn || {};
mn.pipes = mn.pipes || {};
mn.pipes.MnPrettyVersion =
  (function () {
    "use strict";

    var MnPrettyVersion =
        ng.core.Pipe({
          name: "mnPrettyVersion"
        }).Class({
          constructor: [
            mn.pipes.MnParseVersion,
            function MnPrettyVersionPipe(mnParseVersion) {
              this.mnParseVersion = mnParseVersion;
            }],
          transform: function (str, full) {
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
        });

    return MnPrettyVersion;
  })();

var mn = mn || {};
mn.modules = mn.modules || {};
mn.modules.MnPipesModule =
  (function () {
    "use strict";

    var MnPipesModule =
        ng.core.NgModule({
          declarations: [
            mn.pipes.MnParseVersion,
            mn.pipes.MnPrettyVersion
          ],
          imports: [],
          providers: [
            mn.pipes.MnParseVersion,
            mn.pipes.MnPrettyVersion
          ]
        })
        .Class({
          constructor: function MnPipesModule() {}
        });

    return MnPipesModule;
  })();
