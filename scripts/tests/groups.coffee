screenshotsOutputPath = casper.cli.options["screenshots-output-path"]
baseURL = casper.cli.options["base-url"]
rootSelector = "#js_groups"
casper.options.viewportSize = width: 1000, height: 800

casper.test.begin('groups section', 0, () ->
  casper.start("#{baseURL}#sec=groups").then(() ->
    casper.evaluate () ->
      DAL.cells.isEnterpriseCell.setValue true

  ).waitUntilVisible("#{rootSelector} .casper_edit_group_start", () ->

    @capture "#{screenshotsOutputPath}groups.png"
    @click "#{rootSelector} .casper_create_group_start"

  ).waitUntilVisible(".casper_add_group_dialog", () ->
    @capture "#{screenshotsOutputPath}groups-create_group_dialog.png"
    @click ".casper_close_add_group_dialog"
    @click "#{rootSelector} .casper_edit_group_start"

  ).waitUntilVisible(".casper_edit_group_dialog", () ->
    @capture "#{screenshotsOutputPath}groups-edit_group_dialog.png"
    @click ".casper_close_edit_group_dialog"
    @click "#{rootSelector} .casper_remove_group_start"

    @capture "#{screenshotsOutputPath}groups-remove_group_dialog.png"
    @click ".casper_close_remove_group_dialog"

    @mouse.down 500, 300
    @mouse.move 550, 350
    @capture "#{screenshotsOutputPath}groups-dragged_server.png"
    @mouse.up 500, 360

    @click "#{rootSelector} .casper_group_apply_start"
  ).waitUntilVisible(".casper_groups_warning_message", () ->
    @capture "#{screenshotsOutputPath}groups-revision_mismatch.png"

  ).run(() ->
    @test.done()

  )
)