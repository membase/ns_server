ns = global.ns
ns.tester.begin "xdcr section", 0, ->
  casper.start "#{ns.baseURL}#sec=replications"
  casper.then -> @tickFarAway()
  casper.then -> ns.phantomcss.screenshot "_casper_xdcr"
  casper.run  -> ns.tester.done()

