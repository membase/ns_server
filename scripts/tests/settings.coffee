screenshotsOutputPath = casper.cli.options["screenshots-output-path"]
baseURL = casper.cli.options["base-url"]
rootSelector = "#js_views"
casper.options.viewportSize = width: 1000, height: 800

casper.test.begin('settings section', 0, () ->
  casper.start("#{baseURL}#sec=settings").then(() ->
    @capture "#{screenshotsOutputPath}settings-update-notifications.png"
    @click "#settings_auto_failover"

  ).waitUntilVisible("#auto_failover_container", () ->
    @capture "#{screenshotsOutputPath}settings-auto_failover_container.png"
    @click "#settings_alerts"

  ).waitUntilVisible("#email_alerts_container", () ->
    @capture "#{screenshotsOutputPath}settings-email_alerts_container.png"
    @click "#settings_compaction"

  ).waitUntilVisible("#compaction_container", () ->
    @capture "#{screenshotsOutputPath}settings-compaction_container.png"
    @click "#settings_sample_buckets"

  ).waitUntilVisible("#sample_buckets_container", () ->
    @capture "#{screenshotsOutputPath}settings-sample_buckets_container.png"
    @click "#account_management"

  ).waitUntilVisible(".account_management_container", () ->
    @capture "#{screenshotsOutputPath}account_management_container.png"

  ).run(() ->
    @test.done()))
