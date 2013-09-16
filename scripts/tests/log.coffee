screenshotsOutputPath = casper.cli.options["screenshots-output-path"]
baseURL = casper.cli.options["base-url"]
casper.options.viewportSize = width: 1000, height: 800

casper.test.begin('log section', 0, () ->
  casper.start("#{baseURL}#sec=log").waitUntilVisible(".casper_logs_container_visible", () ->
    @capture "#{screenshotsOutputPath}log.png"

  ).run(() ->
    @test.done()))
