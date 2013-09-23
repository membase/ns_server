screenshotsOutputPath = casper.cli.options["screenshots-output-path"]
baseURL = casper.cli.options["base-url"]
casper.options.viewportSize = width: 1000, height: 800

casper.test.begin('overview section', 0, () ->
  casper.start("#{baseURL}#sec=overview").then(() ->
    @capture "#{screenshotsOutputPath}overview-waiting_for_samples.png"

  ).waitUntilVisible(".casper_overview_reads_graph canvas", () ->
    @capture "#{screenshotsOutputPath}overview.png"

  ).run(() ->
    @test.done()))
