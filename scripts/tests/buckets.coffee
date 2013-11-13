rootSelector = "#js_buckets"

casper.test.begin('buckets section', 0, () ->
  casper.start("#{casper.baseURL}#sec=buckets").then(() ->
    @tickFarAway()
    @capture "#{casper.screenshotsOutputPath}buckets.png"
    @click "#{rootSelector} .casper_create_bucket_button"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}buckets-add_bucket_dialog.png"
    @click "#{rootSelector} .casper_open_bucket_details span"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}buckets-additional_server_info-open.png"
    @click "#{rootSelector} .casper_edit_bucket_popup"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}buckets-bucket_details_dialog.png"

  ).run(() ->
    @test.done()))
