ns = global.ns
ns.tester.begin "overview section", 0, ->
  casper.start "#{ns.baseURL}#sec=overview"
  casper.then -> @tickFarAway()
  casper.then -> ns.phantomcss.screenshot "_casper_overview"
  casper.thenClickAndTickWithShot ".casper_internal_settings_popup",
    -> @click ".casper_internal_settings_close"
  casper.run -> ns.tester.done()
