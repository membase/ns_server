casper.test.begin('xdcr section', 0, () ->
  casper.start("#{casper.baseURL}#sec=replications").then(() ->
    @tickFarAway()
    @capture "#{casper.screenshotsOutputPath}xdcr.png"

  ).run(() ->
    @test.done()))
