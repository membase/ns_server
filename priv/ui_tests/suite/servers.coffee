rootSelector = "#js_servers"
ns = global.ns
ns.tester.begin "servers section", 0, ->
  casper.start "#{ns.baseURL}#sec=servers"
  casper.then -> @tickFarAway()
  casper.then -> ns.phantomcss.screenshot "_casper_servers"

  casper.thenClickAndTickWithShot ".casper_servers_add_popup",
    -> @click ".casper_close_join_cluster_dialog"

  casper.then ->
    allActive =
      casper.evaluate ->
        makeSafeForCSS active.otpNode for active in DAL.cells.serversCell.value.active when active.status is "healthy"

    @clickAndTick(".casper_open_cluster_#{allActive[0]}")
  casper.then -> ns.phantomcss.screenshot "_casper_servers_open_cluster"

  casper.thenClickAndTickWithShot ".casper_servers_remove_popup",
    -> @click ".casper_close_eject_confirmation_dialog"
  casper.thenClickAndTickWithShot ".casper_servers_failover_popup",
    -> @click ".casper_close_failover_confirmation_dialog"
  casper.thenClickAndTickWithShot ".casper_servers_pending_rebalance_tab"

  casper.run -> ns.tester.done()
