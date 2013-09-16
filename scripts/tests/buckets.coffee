screenshotsOutputPath = casper.cli.options["screenshots-output-path"]
baseURL = casper.cli.options["base-url"]
rootSelector = "#js_buckets"
casper.options.viewportSize = width: 1000, height: 800

casper.test.begin('buckets section', 0, () ->
  casper.start("#{baseURL}#sec=buckets").then(() ->
    @capture "#{screenshotsOutputPath}buckets.png"
    @click "#{rootSelector} .casper_create_bucket_button"

  ).waitUntilVisible(".casper_bucket_details_dialog", () ->
    @capture "#{screenshotsOutputPath}buckets-add_bucket_dialog.png"
    casper.evaluate () ->
      $(".casper_open_bucket_details span").click()

  ).waitUntilVisible(".casper_additional_bucket_info_open", () ->
    @capture "#{screenshotsOutputPath}buckets-additional_server_info-open.png"
    @click "#{rootSelector} .casper_edit_bucket_popup"

  ).waitUntilVisible(".casper_bucket_details_dialog", () ->
    @capture "#{screenshotsOutputPath}buckets-bucket_details_dialog.png"

  ).run(() ->
    @test.done()))
