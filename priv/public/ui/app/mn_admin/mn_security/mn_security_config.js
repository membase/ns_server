(function () {
  "use strict";

  angular.module('mnSecurity', [
    'mnExternalRoles',
    'mnPluggableUiRegistry',
    'mnRootCertificate'
  ]).config(mnIndexesConfig);

  function mnIndexesConfig($stateProvider) {
    $stateProvider
      .state('app.admin.security', {
        abstract: true,
        controller: "mnSecurityController as securityCtl",
        templateUrl: "app/mn_admin/mn_security/mn_security.html"
      })
      .state('app.admin.security.rootCertificate', {
        url: '/rootCertificate',
        controller: 'mnRootCertificateController as rootCertificateCtl',
        templateUrl: 'app/mn_admin/mn_security/mn_root_certificate/mn_root_certificate.html',
        data: {
          required: {
            enterprise: true
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