screenshotsOutputPath = casper.cli.options["screenshots-output-path"]
baseURL = casper.cli.options["base-url"]
casper.options.viewportSize = width: 1000, height: 800

casper.test.begin('xdcr section', 0, () ->
  casper.start("#{baseURL}#sec=replications").waitUntilVisible(".casper_remout_cluster_container", () ->
    @capture "#{screenshotsOutputPath}xdcr.png"

  ).run(() ->
    @test.done()))
