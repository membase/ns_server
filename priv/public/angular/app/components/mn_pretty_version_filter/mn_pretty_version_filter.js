angular.module('mnPrettyVersionFilter').filter('mnPrettyVersionFilter', function () {
  function parseVersion(str) { // Example: "1.8.0r-9-ga083a1e-enterprise"
    var a = str.split(/[-_]/);
    a[0] = (a[0].match(/[0-9]+\.[0-9]+\.[0-9]+/) || ["0.0.0"])[0];
    a[1] = a[1] || "0";
    a[2] = a[2] || "unknown";
    a[3] = (a[3] && (a[3].substr(0, 1).toUpperCase() + a[3].substr(1))) || "DEV";
    return a; // Example result: ["1.8.0", "9", "ga083a1e", "Enterprise"]
  }

  return function (str, full) {
    if (!str) {
      return;
    }
    var a = parseVersion(str);
    // Example default result: "1.8.0 Enterprise Edition (build-7)"
    // Example full result: "1.8.0 Enterprise Edition (build-7-g35c9cdd)"
    var suffix = "";
    if (full) {
      suffix = '-' + a[2];
    }
    return [a[0], a[3], "Edition", "(build-" + a[1] + suffix + ")"].join(' ');
  }
});