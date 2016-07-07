(function () {
  "use strict";

  angular
    .module('mnSettings', [
      'mnSettingsNotifications',
      'mnLdap',
      'mnSettingsSampleBuckets',
      'mnSettingsCluster',
      'mnSettingsAutoFailover',
      'mnSettingsAutoCompaction',
      'mnAudit',
      'mnSettingsCluster',
      'mnSettingsAlerts',
      'mnSettingsNotificationsService',
      'mnInternalRoles',
      'ui.router',
      'mnPluggableUiRegistry'
    ])
    .config(mnSettingsConfig);

  function mnSettingsConfig($stateProvider) {

    $stateProvider
      .state('app.admin.settings', {
        url: '/settings',
        abstract: true,
        templateUrl: 'mn_admin/mn_settings/mn_settings.html',
        controller: 'mnSettingsController as settingsCtl'
      })
      .state('app.admin.settings.cluster', {
        url: '/cluster',
        controller: 'mnSettingsClusterController as settingsClusterCtl',
        templateUrl: 'mn_admin/mn_settings/cluster/mn_settings_cluster.html'
      })
      .state('app.admin.settings.notifications', {
        url: '/notifications',
        controller: 'mnSettingsNotificationsController as settingsNotificationsCtl',
        templateUrl: 'mn_admin/mn_settings/notifications/mn_settings_notifications.html',
        data: {
          permissions: 'cluster.settings.read'
        }
      })
      .state('app.admin.settings.autoFailover', {
        url: '/autoFailover',
        controller: 'mnSettingsAutoFailoverController as settingsAutoFailoverCtl',
        templateUrl: 'mn_admin/mn_settings/auto_failover/mn_settings_auto_failover.html',
        data: {
          permissions: 'cluster.settings.read'
        }
      })
      .state('app.admin.settings.alerts', {
        url: '/alerts',
        controller: 'mnSettingsAlertsController as settingsAlertsCtl',
        templateUrl: 'mn_admin/mn_settings/alerts/mn_settings_alerts.html',
        data: {
          permissions: 'cluster.settings.read'
        }
      })
      .state('app.admin.settings.autoCompaction', {
        url: '/autoCompaction',
        controller: 'mnSettingsAutoCompactionController as settingsAutoCompactionCtl',
        templateUrl: 'mn_admin/mn_settings/auto_compaction/mn_settings_auto_compaction.html',
        data: {
          permissions: 'cluster.settings.read'
        }
      })
      .state('app.admin.settings.sampleBuckets', {
        url: '/sampleBuckets',
        controller: 'mnSettingsSampleBucketsController as settingsSampleBucketsCtl',
        templateUrl: 'mn_admin/mn_settings/sample_buckets/mn_settings_sample_buckets.html',
        data: {
          permissions: 'cluster.samples.read'
        }
      });
  }
})();
