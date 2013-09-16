screenshotsOutputPath = casper.cli.options["screenshots-output-path"]
baseURL = casper.cli.options["base-url"]
rootSelector = "#js_servers"
casper.options.viewportSize = width: 1000, height: 800

casper.test.begin('servers section', 0, () ->
  casper.start("#{baseURL}#sec=servers").then(() ->
    @capture "#{screenshotsOutputPath}servers.png"
    @click "#{rootSelector} .casper_server_add"

  ).waitUntilVisible(".casper_join_cluster_dialog", () ->
    @capture "#{screenshotsOutputPath}servers-join_cluster_dialog.png"
    @click ".casper_close_join_cluster_dialog"

    allActive = casper.evaluate () ->
      servers = DAL.cells.serversCell.value.active
      makeSafeForCSS active.otpNode for active in servers when active.status is "healthy"

    @click "#{rootSelector} .casper_open_cluster_#{allActive[0]}"

  ).waitUntilVisible(".casper_additional_server_info_open", () ->
    @capture "#{screenshotsOutputPath}servers-additional_server_info.png"
    @click "#{rootSelector} .casper_eject_server_remove"

  ).waitUntilVisible(".casper_eject_confirmation_dialog", () ->
    @capture "#{screenshotsOutputPath}servers-eject_confirmation_dialog.png"
    @click ".casper_close_eject_confirmation_dialog"
    @click "#{rootSelector} .casper_failover_server_remove"

  ).waitUntilVisible(".casper_failover_confirmation_dialog", () ->
    @capture "#{screenshotsOutputPath}servers-failover_confirmation_dialog.png"
    @click ".casper_close_failover_confirmation_dialog"
    @click "#{rootSelector} .casper_pending_rebalance_tab"

  ).waitUntilVisible("#{rootSelector} .casper_pending_server_list", () ->
    @capture "#{screenshotsOutputPath}servers-pending-rebalance-tab.png"

  ).run(() ->
    @test.done()

  )
)
