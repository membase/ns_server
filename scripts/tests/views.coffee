rootSelector = "#js_views"

casper.test.begin('views section', 0, () ->
  casper.start("#{casper.baseURL}#sec=views").then(() ->
    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}views.png"
    @click "#{rootSelector} .create_view a"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}views-copy_view_dialog.png"
    @click "#{rootSelector} [href=\"#deleteDDoc=_design%2Fdev_test_one\"]"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}views-delete_designdoc_confirmation_dialog.png"
    @click "#{rootSelector} .tab_right a"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}views-production_views_list.png"
    @click "[href=\"#showView=default%2F_design%252Fa%2F_view%2Fview%2520name\"]"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}views-open.png"

  ).run(() ->
    @test.done()))