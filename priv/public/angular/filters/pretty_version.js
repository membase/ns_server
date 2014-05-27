angular.module('filters', []).filter('prettyVersion', function () {
  function parseVersion(str) { // Example: "1.8.0r-9-ga083a1e-enterprise"
    var a = str.split(/[-_]/);
    a[0] = (a[0].match(/[0-9]+\.[0-9]+\.[0-9]+/) || ["0.0.0"])[0]
    a[1] = a[1] || "0"
    a[2] = a[2] || "unknown"
    a[3] = a[3] || "DEV"
    return a; // Example result: ["1.8.0", "9", "ga083a1e", "enterprise"]
  }

  return function (str, full) {
    var a = parseVersion(str);
    // Example default result: "1.8.0 enterprise edition (build-7)"
    // Example full result: "1.8.0 enterprise edition (build-7-g35c9cdd)"
    var suffix = "";
    if (full) {
      suffix = '-' + a[2];
    }
    return [a[0], a[3], "edition", "(build-" + a[1] + suffix + ")"].join(' ');
  }
});