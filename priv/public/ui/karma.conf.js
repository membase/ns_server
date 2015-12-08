module.exports = function (config) {
  config.set({

    // base path that will be used to resolve all patterns (eg. files, exclude)
    basePath: '.',

    // frameworks to use
    // available frameworks: e
    frameworks: [
      'jasmine-jquery',
      'jasmine'
    ],

    // list of files / patterns to load in the browser
    files: [
      'libs/angular.js',
      'libs/angular-mocks.js',
      'libs/angular-sanitize.js',
      'libs/angular-ui-bootstrap.js',
      'libs/angular-ui-router.js',
      'libs/angular-ui-select.js',
      'libs/lodash.compat.js',
      'angular-templates-list.js',
      'app/app.js',
      'app/app_config.js',
      'app/app_controller.js',
      'app/mn_admin/mn_admin_config.js',
      'app/mn_admin/mn_admin_controller.js',
      'app/mn_admin/mn_overview/mn_overview_controller.js',
      'app/mn_admin/mn_overview/mn_overview_service.js',
      'app/mn_admin/mn_analytics/mn_analytics_controller.js',
      'app/mn_admin/mn_analytics/mn_analytics_list_controller.js',
      'app/mn_admin/mn_analytics/mn_analytics_list_graph_controller.js',
      'app/mn_admin/mn_analytics/mn_analytics_service.js',
      'app/mn_admin/mn_servers/mn_servers_controller.js',
      'app/mn_admin/mn_servers/mn_servers_service.js',
      'app/mn_admin/mn_servers/details/mn_servers_list_item_details_controller.js',
      'app/mn_admin/mn_servers/details/mn_servers_list_item_details_service.js',
      'app/mn_admin/mn_servers/eject_dialog/mn_servers_eject_dialog_controller.js',
      'app/mn_admin/mn_servers/add_dialog/mn_servers_add_dialog_controller.js',
      'app/mn_admin/mn_servers/failover_dialog/mn_servers_failover_dialog_controller.js',
      'app/mn_admin/mn_servers/memory_quota_dialog/memory_quota_dialog_controller.js',
      'app/mn_admin/mn_buckets/mn_buckets_service.js',
      'app/mn_admin/mn_buckets/mn_buckets_controller.js',
      'app/mn_admin/mn_buckets/list/mn_buckets_list_directive.js',
      'app/mn_admin/mn_buckets/details/mn_buckets_details_controller.js',
      'app/mn_admin/mn_buckets/details/mn_buckets_details_service.js',
      'app/mn_admin/mn_buckets/details_dialog/mn_buckets_details_dialog_controller.js',
      'app/mn_admin/mn_buckets/details_dialog/mn_buckets_details_dialog_service.js',
      'app/mn_admin/mn_buckets/delete_dialog/mn_buckets_delete_dialog_controller.js',
      'app/mn_admin/mn_buckets/flush_dialog/mn_buckets_flush_dialog_controller.js',
      'app/mn_admin/mn_indexes/mn_views/mn_views_service.js',
      'app/mn_admin/mn_indexes/mn_views/mn_views_controller.js',
      'app/mn_admin/mn_indexes/mn_views/create_dialog/mn_views_create_dialog_controller.js',
      'app/mn_admin/mn_indexes/mn_views/delete_ddoc_dialog/mn_views_delete_ddoc_dialog_controller.js',
      'app/mn_admin/mn_indexes/mn_views/delete_view_dialog/mn_views_delete_view_dialog_controller.js',
      'app/mn_admin/mn_indexes/mn_views/copy_dialog/mn_views_copy_dialog_controller.js',
      'app/mn_admin/mn_indexes/mn_indexes_service.js',
      'app/mn_admin/mn_indexes/mn_indexes_controller.js',
      'app/mn_admin/mn_settings/auto_failover/mn_settings_auto_failover_service.js',
      'app/mn_admin/mn_settings/auto_failover/mn_settings_auto_failover_controller.js',
      'app/mn_admin/mn_settings/cluster/mn_settings_cluster_service.js',
      'app/mn_admin/mn_settings/cluster/mn_settings_cluster_controller.js',
      'app/mn_admin/mn_settings/notifications/mn_settings_notifications_service.js',
      'app/mn_admin/mn_settings/notifications/mn_settings_notifications_controller.js',
      'app/mn_admin/mn_settings/alerts/mn_settings_alerts_service.js',
      'app/mn_admin/mn_settings/alerts/mn_settings_alerts_controller.js',
      'app/mn_admin/mn_settings/auto_compaction/mn_settings_auto_compaction_service.js',
      'app/mn_admin/mn_settings/auto_compaction/mn_settings_auto_compaction_controller.js',
      'app/mn_admin/mn_settings/audit/mn_settings_audit_service.js',
      'app/mn_admin/mn_settings/audit/mn_settings_audit_controller.js',
      'app/mn_admin/mn_xdcr/mn_xdcr_service.js',
      'app/mn_admin/mn_xdcr/mn_xdcr_controller.js',
      'app/mn_admin/mn_xdcr/settings/mn_xdcr_settings.js',
      'app/mn_admin/mn_xdcr/reference_dialog/mn_xdcr_reference_dialog_controller.js',
      'app/mn_admin/mn_xdcr/create_dialog/mn_xdcr_create_dialog_controller.js',
      'app/mn_admin/mn_xdcr/delete_reference_dialog/mn_xdcr_delete_reference_dialog_controller.js',
      'app/mn_admin/mn_xdcr/delete_dialog/mn_xdcr_delete_dialog_controller.js',
      'app/mn_admin/mn_xdcr/edit_dialog/mn_xdcr_edit_dialog_controller.js',
      'app/mn_admin/mn_logs/mn_logs_service.js',
      'app/mn_admin/mn_logs/mn_logs_controller.js',
      'app/mn_admin/mn_logs/collect_info/mn_logs_collect_info_service.js',
      'app/mn_admin/mn_logs/collect_info/mn_logs_collect_info_controller.js',
      'app/mn_admin/mn_logs/list/mn_logs_list_controller.js',
      'app/mn_wizard/mn_wizard_config.js',
      'app/mn_wizard/step1/mn_wizard_step1_controller.js',
      'app/mn_wizard/step1/mn_wizard_step1_service.js',
      'app/mn_wizard/step2/mn_wizard_step2_controller.js',
      'app/mn_wizard/step2/mn_wizard_step2_service.js',
      'app/mn_wizard/step3/mn_wizard_step3_controller.js',
      'app/mn_wizard/step3/mn_wizard_step3_service.js',
      'app/mn_wizard/step4/mn_wizard_step4_controller.js',
      'app/mn_wizard/step4/mn_wizard_step4_service.js',
      'app/mn_wizard/step5/mn_wizard_step5_controller.js',
      'app/mn_wizard/step5/mn_wizard_step5_service.js',
      'app/mn_wizard/step6/mn_wizard_step6_controller.js',
      'app/components/directives/mn_bar_usage/mn_bar_usage.js',
      'app/components/directives/mn_buckets_form/mn_buckets_form.js',
      'app/components/directives/mn_auto_compaction_form/mn_auto_compaction_form.js',
      'app/components/directives/mn_vertical_bar/mn_vertical_bar.js',
      'app/components/directives/mn_warmup_progress/mn_warmup_progress.js',
      'app/components/directives/mn_focus.js',
      'app/components/directives/mn_spinner.js',
      'app/components/directives/mn_plot.js',
      'app/components/directives/mn_launchpad.js',
      'app/components/directives/mn_sortable_table.js',
      'app/components/directives/mn_memory_quota/mn_memory_quota.js',
      'app/components/directives/mn_memory_quota/mn_memory_quota_service.js',
      'app/components/directives/mn_services/mn_services.js',
      'app/components/mn_filters.js',
      'app/components/mn_jquery.js',
      'app/components/mn_http.js',
      'app/components/mn_pending_query_keeper.js',
      'app/components/mn_helper.js',
      'app/components/mn_poll.js',
      'app/components/mn_promise_helper.js',
      'app/components/mn_pools.js',
      'app/components/mn_pool_default.js',
      'app/components/mn_tasks_details.js',
      'app/components/mn_compaction.js',
      'app/components/mn_alerts.js',
      'app/constants/constants.js',
      'app/mn_auth/mn_auth_config.js',
      'app/mn_auth/mn_auth_controller.js',
      'app/mn_auth/mn_auth_service.js',
      'spec/**/*.js',

      // fixtures
      {pattern: 'app/**/*.json', watched: true, served: true, included: false}
    ],

    // list of files to exclude
    exclude: [],

    // preprocess matching files before serving them to the browser
    // available preprocessors: https://npmjs.org/browse/keyword/karma-preprocessor
    preprocessors: {},

    // test results reporter to use
    // possible values: 'dots', 'progress'
    // available reporters: https://npmjs.org/browse/keyword/karma-reporter
    reporters: ['progress'],

    // web server port
    port: 9876,

    // enable / disable colors in the output (reporters and logs)
    colors: true,

    // level of logging
    // possible values: config.LOG_DISABLE || config.LOG_ERROR || config.LOG_WARN || config.LOG_INFO || config.LOG_DEBUG
    logLevel: config.LOG_INFO,

    // enable / disable watching file and executing tests whenever any file changes
    autoWatch: true,

    // start these browsers
    // available browser launchers: https://npmjs.org/browse/keyword/karma-launcher
    browsers: [
      'Chrome'
    ],

    // Continuous Integration mode
    // if true, Karma captures browsers, runs the tests and exits
    singleRun: false
  })
};
