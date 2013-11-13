rootSelector = "#js_servers"

casper.test.begin('servers section', 0, () ->
  casper.start("#{casper.baseURL}#sec=servers").then(() ->
    @tickFarAway()
    @capture "#{casper.screenshotsOutputPath}servers.png"
    @click "#{rootSelector} .casper_server_add"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}servers-join_cluster_dialog.png"
    @click ".casper_close_join_cluster_dialog"

    allActive = casper.evaluate () ->
      servers = DAL.cells.serversCell.value.active
      makeSafeForCSS active.otpNode for active in servers when active.status is "healthy"

    @click "#{rootSelector} .casper_open_cluster_#{allActive[0]}"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}servers-additional_server_info.png"
    @click "#{rootSelector} .casper_eject_server_remove"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}servers-eject_confirmation_dialog.png"
    @click ".casper_close_eject_confirmation_dialog"
    @click "#{rootSelector} .casper_failover_server_remove"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}servers-failover_confirmation_dialog.png"
    @click ".casper_close_failover_confirmation_dialog"
    @click "#{rootSelector} .casper_pending_rebalance_tab"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}servers-pending-rebalance-tab.png"

  ).run(() ->
    @test.done()

  )
)
