ns = global.ns
ns.tester.begin "log section", 0, ->
  casper.start "#{ns.baseURL}#sec=log"
  casper.then -> @tickFarAway()
  casper.then -> ns.phantomcss.screenshot "_casper_log"
  casper.run -> ns.tester.done()
