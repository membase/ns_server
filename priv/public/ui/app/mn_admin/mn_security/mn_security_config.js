(function () {
  "use strict";

  angular.module('mnSecurity', [
    'mnUserRoles',
    'mnPluggableUiRegistry',
    'mnRootCertificate',
    'mnElementCrane'
  ]).config(mnIndexesConfig);

  function mnIndexesConfig($stateProvider) {
    $stateProvider
      .state('app.admin.security', {
        abstract: true,
        views: {
          "main@app.admin": {
            controller: "mnSecurityController as securityCtl",
            templateUrl: "app/mn_admin/mn_security/mn_security.html"
          }
        },
        data: {
          permissions: "cluster.admin.security.read",
          title: "Security"
        }
      })
      .state('app.admin.security.userRoles', {
        url: "/userRoles?openedUsers&{pageNumber:int}&{pageLimit:int}",
        params: {
          openedUsers: {
            array: true,
            dynamic: true
          },
          pageNumber: {
            value: 1,
            dynamic: true
          },
          pageLimit: {
            value: 10,
            dynamic: true
          }
        },
        controller: "mnUserRolesController as userRolesCtl",
        templateUrl: "app/mn_admin/mn_security/mn_user_roles/mn_user_roles.html",
        data: {
          compat: "atLeast45",
          enterprise: true
        }
      })
      .state('app.admin.security.rootCertificate', {
        url: '/rootCertificate',
        controller: 'mnRootCertificateController as rootCertificateCtl',
        templateUrl: 'app/mn_admin/mn_security/mn_root_certificate/mn_root_certificate.html',
        data: {
          enterprise: true
        }
      })
      .state('app.admin.security.ldap', {
        url: '/ldap',
        controller: 'mnLdapController as ldapCtl',
        templateUrl: 'app/mn_admin/mn_security/mn_ldap/mn_ldap.html',
        data: {
          ldap: true,
          compat: "atLeast40 && !atLeast45",
          enterprise: true
        }
      })
      .state('app.admin.security.audit', {
        url: '/audit',
        controller: 'mnAuditController as auditCtl',
        templateUrl: 'app/mn_admin/mn_security/mn_audit/mn_audit.html',
        data: {
          enterprise: true,
          compat: "atLeast40"
        }
      });
  }
})();
