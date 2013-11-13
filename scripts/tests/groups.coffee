rootSelector = "#js_groups"

casper.test.begin('groups section', 0, () ->
  casper.start("#{casper.baseURL}#sec=groups").then(() ->
    casper.evaluate () ->
      DAL.cells.isEnterpriseCell.setValue true

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}groups.png"
    @click "#{rootSelector} .casper_create_group_start"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}groups-create_group_dialog.png"
    @click ".casper_close_add_group_dialog"
    @click "#{rootSelector} .casper_edit_group_start"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}groups-edit_group_dialog.png"
    @click ".casper_close_edit_group_dialog"
    @click "#{rootSelector} .casper_remove_group_start"

    @capture "#{casper.screenshotsOutputPath}groups-remove_group_dialog.png"
    @click ".casper_close_remove_group_dialog"

    @mouse.down 500, 300
    @mouse.move 550, 350
    @capture "#{casper.screenshotsOutputPath}groups-dragged_server.png"
    @mouse.up 500, 360

    @click "#{rootSelector} .casper_group_apply_start"

    @tickFarAway()

    @capture "#{casper.screenshotsOutputPath}groups-revision_mismatch.png"

  ).run(() ->
    @test.done()

  )
)