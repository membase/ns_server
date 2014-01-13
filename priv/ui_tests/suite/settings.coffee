rootSelector = "#js_settings"
ns = global.ns
ns.tester.begin "settings section", 0, ->
  casper.start "#{ns.baseURL}#sec=settings"
  casper.then -> @tickFarAway()
  casper.then -> ns.phantomcss.screenshot "_casper_settings_cluster_tab"

  casper.thenClickAndTickWithShot ".casper_settings_update_notifications"
  casper.thenClickAndTickWithShot ".casper_settings_software_update_tooltip"
  casper.thenClickAndTickWithShot ".casper_settings_auto_failover"
  casper.thenClickAndTickWithShot ".casper_settings_auto_failover_enabled"
  casper.thenClickAndTickWithShot ".casper_settings_auto_failover_timeout_tooltip"
  casper.thenClickAndTickWithShot ".casper_settings_alerts"
  casper.thenClickAndTickWithShot ".casper_settings_alerts_errors"
  casper.thenClickAndTickWithShot ".casper_settings_compaction"
  casper.thenClickAndTickWithShot ".casper_settings_sample_buckets"
  casper.thenClickAndTickWithShot ".casper_settings_sample_warnign label"
  casper.thenClickAndTickWithShot ".casper_settings_account_management"
  casper.thenClickAndTickWithShot ".casper_settings_account_reset_popup",
    -> @click ".casper_roadmin_reset_dialog_cancel"
  casper.thenClickAndTickWithShot ".casper_settings_account_delete_popup"
  casper.thenClickAndTickWithShot ".casper_settings_roadmin_remove_click"
  casper.thenClickAndTickWithShot ".casper_settings_create_accaunt"
  casper.run -> ns.tester.done()
