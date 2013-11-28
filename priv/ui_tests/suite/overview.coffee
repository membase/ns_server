ns = global.ns
ns.tester.begin "overview section", 0, ->
  casper.start "#{ns.baseURL}#sec=overview"
  casper.then -> @tickFarAway()
  casper.then -> ns.phantomcss.screenshot "_casper_overview"
  casper.run -> ns.tester.done()
