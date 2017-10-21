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
        url: "/security",
        views: {
          "main@app.admin": {
            controller: "mnSecurityController as securityCtl",
            templateUrl: "app/mn_admin/mn_security/mn_security.html"
          }
        },
        data: {
          title: "Security"
        },
        redirectTo: function (trans) {
          var mnPoolDefault = trans.injector().get("mnPoolDefault");
          var mnPermissions = trans.injector().get("mnPermissions");
          var isEnterprise = trans.injector().get("mnPools").export.isEnterprise;
          var ldapEnabled = mnPoolDefault.export.ldapEnabled;
          var atLeast50 = mnPoolDefault.export.compat.atLeast50;
          var atLeast45 = mnPoolDefault.export.compat.atLeast45;
          var securityRead = mnPermissions.export.cluster.admin.security.read;
          if (securityRead) {
            if (atLeast50) {
              return {state: "app.admin.security.userRoles"};
            } else {
              if (isEnterprise && ldapEnabled && atLeast45) {
                return {state: "app.admin.security.externalRoles"};
              } else {
                return {state: "app.admin.security.internalRoles"};
              }
            }
          } else {
            if (isEnterprise) {
              return {state: "app.admin.security.rootCertificate"};
            } else {
              return {state: "app.admin.security.session"}
            }
          }
        }
      })
      .state('app.admin.security.externalRoles', {
        url: "/externalRoles?openedUsers",
        controller: "mnUserRolesController as userRolesCtl",
        templateUrl: "app/mn_admin/mn_security/mn_user_roles/mn_user_roles.html",
        params: {
          openedUsers: {
            array: true,
            dynamic: true
          }
        },
        data: {
          compat: "atLeast45 && !atLeast50",
          ldap: true,
          enterprise: true
        }
      })
      .state('app.admin.security.userRoles', {
        url: "/userRoles?openedUsers&startFrom&startFromDomain&{pageSize:int}",
        params: {
          openedUsers: {
            array: true,
            dynamic: true
          },
          startFrom: {
            value: null
          },
          startFromDomain: {
            value: null
          },
          pageSize: {
            value: 10
          }
        },
        controller: "mnUserRolesController as userRolesCtl",
        templateUrl: "app/mn_admin/mn_security/mn_user_roles/mn_user_roles.html",
        data: {
          compat: "atLeast50"
        }
      })
      .state('app.admin.security.internalRoles', {
        url: '/internalRoles',
        controller: 'mnInternalRolesController as internalRolesCtl',
        templateUrl: 'app/mn_admin/mn_security/mn_internal_roles/mn_internal_roles.html',
        data: {
          permissions: "cluster.admin.security.read",
          compat: "!atLeast50",
        }
      })
      .state('app.admin.security.session', {
        url: '/session',
        controller: 'mnSessionController as sessionCtl',
        templateUrl: 'app/mn_admin/mn_security/mn_session/mn_session.html'
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
