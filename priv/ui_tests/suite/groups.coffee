rootSelector = "#js_groups"
ns = global.ns
ns.tester.begin "groups section", 0, ->
  casper.start "#{ns.baseURL}#sec=groups"
  casper.then ->
    @tickFarAway()
    ns.setEnterprise()
    @tickFarAway()

  casper.then -> ns.phantomcss.screenshot "_casper_groups"

  casper.thenClickAndTickWithShot ".casper_groups_create_popup",
    -> @click ".casper_close_add_group_dialog"
  casper.thenClickAndTickWithShot ".casper_groups_edit_popup",
    -> @click ".casper_close_edit_group_dialog"
  casper.thenClickAndTickWithShot ".casper_groups_remove_popup",
    -> @click ".casper_close_remove_group_dialog"
  casper.thenClickAndTickWithShot ".casper_groups_error"

  casper.run -> ns.tester.done()
