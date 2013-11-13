rootSelector = "#js_settings"

casper.test.begin('settings section', 0, () ->
  casper.start("#{casper.baseURL}#sec=settings").then(() ->
    @tickFarAway()
    @capture "#{casper.screenshotsOutputPath}settings-update_notifications.png"
    @click "#{rootSelector} .casper_software_update_button"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}settings-update_notifications_info.png"
    @click "#{rootSelector} .casper_settings_auto_failover"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}settings-auto_failover_container.png"
    @click "#{rootSelector} .casper_for_enable_replicas"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}settings-auto_failover_container_with_errors.png"
    @click "#{rootSelector} .castep_auto_fail_tooltip_button"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}settings-auto_failover_tooltip.png"
    @click "#{rootSelector} .casper_settings_alerts"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}settings-email_alerts_container.png"
    @click "#{rootSelector} .casper_alerts_errors_start"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}settings-email_alerts_errors_.png"
    @click "#{rootSelector} .casper_settings_compaction"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}settings-compaction_errors.png"
    @click "#{rootSelector} .casper_settings_sample_buckets"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}settings-sample_buckets_container.png"
    @click "#{rootSelector} .casper_samples_warnign_start input"
    @capture "#{casper.screenshotsOutputPath}settings-sample_buckets_warning.png"
    @click "#{rootSelector} .casper_account_management"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}settings-roadmin_user_exist.png"
    @click "#{rootSelector} .casper_reset_acc_btn"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}settings-roadmin_reset_dialog.png"
    @click ".casper_roadmin_reset_dialog_cancel"
    @click "#{rootSelector} .casper_delete_acc_btn"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}settings-roadmin_remove_dialog.png"
    @click ".casper_roadmin_remove_dialog_delete"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}settings-roadmin_form.png"
    @click "#{rootSelector} .casper_do_create_roadmin"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}settings-roadmin_with_errors.png"

  ).run(() ->
    @test.done()))
