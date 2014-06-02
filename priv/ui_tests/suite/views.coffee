rootSelector = "#js_views"
ns = global.ns
ns.tester.begin "views section", 0, ->
  casper.start "#{ns.baseURL}#sec=views"
  casper.then -> @tickFarAway()
  casper.then -> ns.phantomcss.screenshot "_casper_views"

  casper.thenClickAndTickWithShot ".casper_views_create_view_popup"
  casper.thenClickAndTickWithShot ".casper_views_add_spatial_popup"
  casper.thenClickAndTickWithShot ".casper_views_add_view_popup"
  casper.thenClickAndTickWithShot ".casper_views_copy_to_dev"
  casper.thenClickAndTickWithShot ".casper_views_delete_popup"
  casper.thenClickAndTickWithShot ".casper_views_prod_tab"
  casper.thenClickAndTickWithShot ".casper_views_view_tab"
  casper.thenClickAndTickWithShot ".casper_views_save_view_as_popup"

  casper.run -> ns.tester.done()