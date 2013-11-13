casper.test.begin('overview section', 0, () ->
  casper.start("#{casper.baseURL}#sec=overview").then(() ->
    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}overview.png"

  ).run(() ->
    @test.done()))
