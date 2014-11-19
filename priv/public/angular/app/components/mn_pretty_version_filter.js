angular.module('mnPrettyVersionFilter').filter('mnPrettyVersionFilter', function () {
  function parseVersion(str) {
    // Expected string format:
    //   {release version}-{build #}-{Release type or SHA}-{enterprise / community}
    // Example: "1.8.0-9-ga083a1e-enterprise"
    var a = str.split(/[-_]/);
    a[0] = (a[0].match(/[0-9]+\.[0-9]+\.[0-9]+/) || ["0.0.0"])[0];
    a[1] = a[1] || "0";
    a[2] = a[2] || "unknown";
    // We append the build # to the release version when we display in the UI so that
    // customers think of the build # as a descriptive piece of the version they're
    // running (which in the case of maintenance packs and one-off's, it is.)
    a[0] = a[0] + "-" + a[1];
    a[3] = (a[3] && (a[3].substr(0, 1).toUpperCase() + a[3].substr(1))) || "DEV";
    return a; // Example result: ["1.8.0-9", "9", "ga083a1e", "Enterprise"]
  }

  return function (str, full) {
    if (!str) {
      return;
    }
    var a = parseVersion(str);
    // Example default result: "1.8.0-7 Enterprise Edition (build-7)"
    // Example full result: "1.8.0-7 Enterprise Edition (build-7-g35c9cdd)"
    var suffix = "";
    if (full) {
      suffix = '-' + a[2];
    }
    return [a[0], a[3], "Edition", "(build-" + a[1] + suffix + ")"].join(' ');
  }
});