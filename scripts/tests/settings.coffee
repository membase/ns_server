screenshotsOutputPath = casper.cli.options["screenshots-output-path"]
baseURL = casper.cli.options["base-url"]
rootSelector = "#js_settings"
casper.options.viewportSize = width: 1000, height: 800

casper.test.begin('settings section', 0, () ->
  casper.start("#{baseURL}#sec=settings").then(() ->
    @capture "#{screenshotsOutputPath}settings-update_notifications.png"
    @click "#{rootSelector} .casper_software_update_button"

  ).waitUntilVisible("#{rootSelector} .casper_software_update_info", () ->
    @capture "#{screenshotsOutputPath}settings-update_notifications_info.png"
    @click "#{rootSelector} .casper_settings_auto_failover"

  ).waitUntilVisible("#{rootSelector} .casper_auto_failover_container", () ->
    @capture "#{screenshotsOutputPath}settings-auto_failover_container.png"
    @click "#{rootSelector} .casper_for_enable_replicas"

  ).waitForSelectorTextChange("#{rootSelector} .casper_err_timeout", () ->
    @capture "#{screenshotsOutputPath}settings-auto_failover_container_with_errors.png"
    @click "#{rootSelector} .castep_auto_fail_tooltip_button"

  ).waitUntilVisible("#{rootSelector} .castep_auto_fail_tooltip_button .tooltip_msg", () ->
    @capture "#{screenshotsOutputPath}settings-auto_failover_tooltip.png"
    @click "#{rootSelector} .casper_settings_alerts"

  ).waitUntilVisible("#{rootSelector} .casper_email_alerts_container", () ->
    @capture "#{screenshotsOutputPath}settings-email_alerts_container.png"
    @click "#{rootSelector} .casper_alerts_errors_start"
    @click "#{rootSelector} .casper_alerts_errors_start"

  ).waitForSelectorTextChange("#{rootSelector} .casper_alerts_errors_end", () ->
    @capture "#{screenshotsOutputPath}settings-email_alerts_errors_.png"
    @click "#{rootSelector} .casper_settings_compaction"

  ).waitWhileVisible("#{rootSelector} .casper_auto_compaction_wait_spinner + .spinner", () ->
    @capture "#{screenshotsOutputPath}settings-compaction_container.png"

  ).waitWhileVisible("#{rootSelector} .casper_auto_comp_errors_end", () ->
    @capture "#{screenshotsOutputPath}settings-compaction_errors.png"
    @click "#{rootSelector} .casper_settings_sample_buckets"

  ).waitUntilVisible("#{rootSelector} .casper_sample_buckets_container", () ->
    @capture "#{screenshotsOutputPath}settings-sample_buckets_container.png"
    @click "#{rootSelector} .casper_samples_warnign_start input"
    @capture "#{screenshotsOutputPath}settings-sample_buckets_warning.png"
    @click "#{rootSelector} .casper_account_management"

  ).waitUntilVisible("#{rootSelector} .casper_ro_user_exist", () ->
    @capture "#{screenshotsOutputPath}settings-roadmin_user_exist.png"
    @click "#{rootSelector} .casper_reset_acc_btn"

  ).waitUntilVisible(".casper_roadmin_reset_dialog", () ->
    @capture "#{screenshotsOutputPath}settings-roadmin_reset_dialog.png"
    @click ".casper_roadmin_reset_dialog_cancel"
    @click "#{rootSelector} .casper_delete_acc_btn"

  ).waitUntilVisible(".casper_roadmin_remove_dialog", () ->
    @capture "#{screenshotsOutputPath}settings-roadmin_remove_dialog.png"
    @click ".casper_roadmin_remove_dialog_delete"

  ).waitUntilVisible(".casper_roadmin_wait_spinner").waitWhileVisible("#{rootSelector} .casper_roadmin_wait_spinner + .spinner", () ->
    @capture "#{screenshotsOutputPath}settings-roadmin_form.png"
    @click "#{rootSelector} .casper_do_create_roadmin"

  ).waitWhileVisible("#{rootSelector} .casper_roadmin_wait_spinner + .spinner", () ->
    @capture "#{screenshotsOutputPath}settings-roadmin_with_errors.png"

  ).run(() ->
    @test.done()))
