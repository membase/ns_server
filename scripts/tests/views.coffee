screenshotsOutputPath = casper.cli.options["screenshots-output-path"]
baseURL = casper.cli.options["base-url"]
rootSelector = "#js_views"
casper.options.viewportSize = width: 1000, height: 800

casper.test.begin('views section', 0, () ->
  casper.start("#{baseURL}#sec=views").waitUntilVisible("#development_views_list_container .design_doc_name", () ->
    @capture "#{screenshotsOutputPath}views.png"

  ).then(() ->
    @click "#{rootSelector} .create_view a"

  ).waitUntilVisible("[aria-labelledby=\"ui-dialog-title-copy_view_dialog\"]", () ->
    @capture "#{screenshotsOutputPath}views-copy_view_dialog.png"

  ).then(() ->
    @click "#{rootSelector} [href=\"#deleteDDoc=_design%2Fdev_test_one\"]"

  ).waitUntilVisible("#delete_designdoc_confirmation_dialog", () ->
    @capture "#{screenshotsOutputPath}views-delete_designdoc_confirmation_dialog.png"

  ).then(() ->
    @click "#{rootSelector} .tab_right a"

  ).waitUntilVisible("#production_views_list_container", () ->
    @capture "#{screenshotsOutputPath}views-production_views_list.png"

  ).then(() ->
    @click "[href=\"#showView=default%2F_design%252Fa%2F_view%2Fview%2520name\"]"

  ).waitUntilVisible("#sample_documents_container pre", () ->
    @capture "#{screenshotsOutputPath}views-open.png"

  ).run(() ->
    @test.done()))