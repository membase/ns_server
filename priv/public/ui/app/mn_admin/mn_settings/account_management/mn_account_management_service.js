(function () {
  "use strict";

  angular
    .module("mnAccountManagementService", ["mnHttp"])
    .factory("mnAccountManagementService", mnAccountManagementFactory);

  function mnAccountManagementFactory(mnHttp, $q) {
    var mnAccountManagementService = {
      getAccountManagmentState: getAccountManagmentState,
      postReadOnlyAdminName: postReadOnlyAdminName,
      deleteReadOnlyAdmin: deleteReadOnlyAdmin,
      resetReadOnlyAdmin: resetReadOnlyAdmin
    };
    return mnAccountManagementService;

    function resetReadOnlyAdmin(password) {
      return mnHttp({
        method: "PUT",
        url: "/settings/readOnlyUser",
        data: {password: password}
      });
    }
    function getAccountManagmentState() {
      return getReadOnlyAdminName().then(function (resp) {
        return resp.data;
      });
    }
    function deleteReadOnlyAdmin() {
      return mnHttp({
        method: "DELETE",
        url: "/settings/readOnlyUser"
      });
    }
    function getReadOnlyAdminName() {
      return mnHttp({
        method: "GET",
        url: "/settings/readOnlyAdminName"
      });
    }
    function postReadOnlyAdminName(creds, justValidate) {
      if (creds.password.length !== creds.verifyPassword.length) {
        return $q.reject({
          data: {
            errors: {
              verifyPassword: "Password doesn't match"
            }
          }
        });
      } else {
        return mnHttp({
          method: "POST",
          url: "/settings/readOnlyUser",
          data: {
            username: creds.username,
            password: creds.password
          },
          params: {
            just_validate: justValidate ? 1 : 0
          }
        });
      }
    }
  }
})();
