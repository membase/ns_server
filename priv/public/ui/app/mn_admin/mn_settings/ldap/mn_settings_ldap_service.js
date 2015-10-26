(function () {
  angular
    .module('mnSettingsLdapService', ["mnHttp"])
    .factory("mnSettingsLdapService", mnSettingsLdapFactory);

    function mnSettingsLdapFactory(mnHttp) {
      var mnSettingsLdapService = {
        getSaslauthdAuth: getSaslauthdAuth,
        postSaslauthdAuth: postSaslauthdAuth,
        validateCredentials: validateCredentials
      };

      return mnSettingsLdapService;

      function unpack(data, key) {
        if (data[key] === "asterisk") {
          data["default"] = key;
          delete data[key];
        } else {
          data[key] = data[key].join('\n');
        }
      }

      function pack(data, key) {
        if (data["default"] === key) {
          delete data[key];
        } else {
          data[key] = data[key] || "";
        }
      }

      function validateCredentials(user) {
        return mnHttp({
          method: "POST",
          url: "/validateCredentials",
          data: user
        }).then(function (resp) {
          var data = _.clone(resp.data);
          data.test = _.clone(user);
          return data;
        });
      }

      function postSaslauthdAuth(state) {
        state = _.clone(state);
        pack(state, "admins");
        pack(state, "roAdmins");
        delete state["default"];
        return mnHttp({
          method: "POST",
          url: "/settings/saslauthdAuth",
          data: state
        });
      }

      function getSaslauthdAuth() {
        return mnHttp({
          method: "GET",
          url: "/settings/saslauthdAuth"
        }).then(function (resp) {
          var data = _.clone(resp.data);
          unpack(data, "admins");
          unpack(data, "roAdmins");
          data["default"] = data["default"] || "";
          return data;
        });
      }
    }
})();
