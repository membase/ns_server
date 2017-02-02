(function () {
  "use strict";

  angular
    .module("mnResetPasswordDialogService", [
      "ui.bootstrap"
    ])
    .factory("mnResetPasswordDialogService", mnResetPasswordDialogFactory);

  function mnResetPasswordDialogFactory($http, $uibModal, $window) {
    var mnResetPasswordDialogService = {
      post: post,
      showDialog: showDialog
    };

    return mnResetPasswordDialogService;

    function showDialog() {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_reset_password_dialog/mn_reset_password_dialog.html',
        controller: "mnResetPasswordDialogController as resetPasswordDialogCtl"
      });
    }

    function post(user) {

      return $http({
        headers: {
          'Authorization': "Basic " + btoa(user.name + ":" + user.currentPassword),
          'ns-server-ui': undefined
        },
        url: "/controller/changePassword",
        method: "POST",
        data: {
          password: user.password
        }
      }).then(function (resp) {
        return resp.data;
      });
    }
  }
})();
