(function () {
  "use strict";

  angular.module('mnSecurity', [
    'mnExternalRoles',
    'mnPluggableUiRegistry'
  ]).config(mnIndexesConfig);

  function mnIndexesConfig($stateProvider) {
    $stateProvider
      .state('app.admin.security', {
        abstract: true,
        controller: "mnSecurityController as securityCtl",
        templateUrl: "app/mn_admin/mn_security/mn_security.html"
      })
      .state('app.admin.security.externalRoles', {
        url: "/externalRoles",
        controller: "mnExternalRolesController as externalRolesCtl",
        templateUrl: "app/mn_admin/mn_security/mn_external_roles/mn_external_roles.html"
      })
      .state('app.admin.security.internalRoles', {
        url: '/internalRoles',
        controller: 'mnInternalRolesController as internalRolesCtl',
        templateUrl: 'app/mn_admin/mn_security/mn_internal_roles/mn_internal_roles.html',
        data: {
          required: {
            admin: true
          }
        }
      })
      .state('app.admin.security.ldap', {
        url: '/ldap',
        controller: 'mnLdapController as ldapCtl',
        templateUrl: 'app/mn_admin/mn_security/mn_ldap/mn_ldap.html',
        data: {
          required: {
            enterprise: true
          }
        }
      })
      .state('app.admin.security.audit', {
        url: '/audit',
        controller: 'mnAuditController as auditCtl',
        templateUrl: 'app/mn_admin/mn_security/mn_audit/mn_audit.html',
        data: {
          required: {
            enterprise: true
          }
        }
      });
  }
})();