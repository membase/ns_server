(function () {
  "use strict";

  angular
    .module("mnInternalSettingsService", ["mnHttp"])
    .factory("mnInternalSettingsService", mnInternalSettingsFactory);

  function mnInternalSettingsFactory(mnHttp) {
    var mnInternalSettingsService = {
      getState: getState,
      save: save
    };

    return mnInternalSettingsService;

    function save(data) {
      return mnHttp({
        method: "POST",
        url: "/internalSettings",
        data: data
      });
    }

    function getState() {
      return mnHttp({
        method: "GET",
        url: "/internalSettings"
      }).then(function (resp) {
        return resp.data;
      })
    }
  }
})();
