rootSelector = "#js_buckets"
ns = global.ns
ns.tester.begin "buckets section", 0, ->
  casper.start "#{ns.baseURL}#sec=buckets"
  casper.then -> @tickFarAway()
  casper.then -> ns.phantomcss.screenshot "_casper_buckets"

  casper.thenClickAndTickWithShot ".casper_buckets_new_data_bucket"
  casper.thenClickAndTickWithShot ".casper_buckets_bucket_details"
  casper.thenClickAndTickWithShot ".casper_buckets_edit_bucket_popup"

  casper.run -> ns.tester.done()
