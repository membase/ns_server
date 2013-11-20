casper.test.begin('log section', 0, () ->
  casper.start("#{casper.baseURL}#sec=log").then(() ->
    @tickFarAway()
    @capture "#{casper.screenshotsOutputPath}log.png"

  ).run(() ->
    @test.done()))
