(function () {
  "use strict";

  angular
    .module('mnSettings', [
      'mnSettingsNotifications',
      'mnSettingsLdap',
      'mnSettingsSampleBuckets',
      'mnSettingsCluster',
      'mnSettingsAutoFailover',
      'mnSettingsAutoCompaction',
      'mnSettingsAudit',
      'mnSettingsCluster',
      'mnSettingsAlerts',
      'mnSettingsNotificationsService',
      'mnAccountManagement',
      'ui.router'
    ])
    .config(mnSettingsConfig);

  function mnSettingsConfig($stateProvider) {

    $stateProvider
      .state('app.admin.settings', {
        url: '/settings',
        abstract: true,
        templateUrl: 'app/mn_admin/mn_settings/mn_settings.html',
        controller: 'mnSettingsController as settingsCtl'
      })
      .state('app.admin.settings.cluster', {
        url: '/cluster',
        controller: 'mnSettingsClusterController as settingsClusterCtl',
        templateUrl: 'app/mn_admin/mn_settings/cluster/mn_settings_cluster.html'
      })
      .state('app.admin.settings.notifications', {
        url: '/notifications',
        controller: 'mnSettingsNotificationsController as settingsNotificationsCtl',
        templateUrl: 'app/mn_admin/mn_settings/notifications/mn_settings_notifications.html'
      })
      .state('app.admin.settings.autoFailover', {
        url: '/autoFailover',
        controller: 'mnSettingsAutoFailoverController as settingsAutoFailoverCtl',
        templateUrl: 'app/mn_admin/mn_settings/auto_failover/mn_settings_auto_failover.html'
      })
      .state('app.admin.settings.alerts', {
        url: '/alerts',
        controller: 'mnSettingsAlertsController as settingsAlertsCtl',
        templateUrl: 'app/mn_admin/mn_settings/alerts/mn_settings_alerts.html'
      })
      .state('app.admin.settings.autoCompaction', {
        url: '/autoCompaction',
        controller: 'mnSettingsAutoCompactionController as settingsAutoCompactionCtl',
        templateUrl: 'app/mn_admin/mn_settings/auto_compaction/mn_settings_auto_compaction.html'
      })
      .state('app.admin.settings.ldap', {
        url: '/ldap',
        controller: 'mnSettingsLdapController as settingsLdapCtl',
        templateUrl: 'app/mn_admin/mn_settings/ldap/mn_settings_ldap.html',
        data: {
          required: {
            enterprise: true
          }
        }
      })
      .state('app.admin.settings.sampleBuckets', {
        url: '/sampleBuckets',
        controller: 'mnSettingsSampleBucketsController as settingsSampleBucketsCtl',
        templateUrl: 'app/mn_admin/mn_settings/sample_buckets/mn_settings_sample_buckets.html'
      })
      .state('app.admin.settings.accountManagement', {
        url: '/accountManagement',
        controller: 'mnAccountManagementController as accountManagementCtl',
        templateUrl: 'app/mn_admin/mn_settings/account_management/mn_account_management.html',
        data: {
          required: {
            admin: true
          }
        }
      })
      .state('app.admin.settings.audit', {
        url: '/audit',
        controller: 'mnSettingsAuditController as settingsAuditCtl',
        templateUrl: 'app/mn_admin/mn_settings/audit/mn_settings_audit.html',
        data: {
          required: {
            enterprise: true
          }
        }
      });
  }
})();
