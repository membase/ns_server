
var DecimationTest = TestCase("DecimationTest");

DecimationTest.prototype.testCutoff = function () {
  var samples = new Array(100);
  var i = 0;
  for (i=0;i<samples.length;i++) {
    samples[i] = (i & 1) ? 1 : 0;
  }

  var outSamples = decimateSamples(2, samples);

  var avg = _.reduce(outSamples, function (acc, s) {return acc + s}, 0)/outSamples.length;

  var min = Math.min.apply(null, outSamples);
  var max = Math.max.apply(null, outSamples);

  // we test that our filter has nearly completely killed high-freq
  // component
  assertTrue(Math.abs(avg - min) < 0.01);
  assertTrue(Math.abs(avg - max) < 0.01);
}

var ParseHTTPDateTest = TestCase("ParseHTTPDateTest");
ParseHTTPDateTest.prototype.testBasic = function () {
  assertEquals(Date.UTC(2010, 10, 3, 14, 41, 29),
               parseHTTPDate("Wed, 03 Nov 2010 14:41:29 GMT").valueOf())

  // Sun, 06 Nov 1994 08:49:37 GMT  ; RFC 822, updated by RFC 1123
  assertEquals(Date.UTC(1994, 10, 6, 8, 49, 37),
               parseHTTPDate(" Sun, 06 Nov 1994 08:49:37 GMT").valueOf())

  // Sunday, 06-Nov-94 08:49:37 GMT ; RFC 850, obsoleted by RFC 1036
  assertEquals(Date.UTC(1994, 10, 6, 8, 49, 37),
               parseHTTPDate("Sunday, 06-Nov-94 08:49:37 GMT ").valueOf())

  // // Sun Nov  6 08:49:37 1994       ; ANSI C's asctime() format
  assertEquals(Date.UTC(1994, 10, 6, 8, 49, 37),
               parseHTTPDate("Sun Nov  6 08:49:37 1994", "badvalue").valueOf())

  assertEquals("badvalue",
               parseHTTPDate("Asdasdsd asd asd asd", "badvalue").valueOf())
}

var ParseRFC3339DateTest = TestCase("ParseRFC3339DateTest");
ParseRFC3339DateTest.prototype.testBasic = function () {
/*
root@pi:~# TZ='America/Los_Angeles' date --rfc-3339=ns -u
2011-10-18 15:52:44.934297829+00:00
root@pi:~# TZ='America/Los_Angeles' date --rfc-3339=ns
2011-10-18 08:52:47.326164498-07:00
root@pi:~# date --rfc-3339=ns
2011-10-18 18:55:13.142337777+03:00
 */

  var d1 = parseRFC3339Date("2011-10-18 15:52:35.928687640+00:00");
  assertTrue(d1 instanceof Date);
  assertEquals(Date.UTC(2011, 9, 18, 15, 52, 35, 929),
               parseRFC3339Date("2011-10-18 15:52:35.928687640+00:00").valueOf());

  assertEquals(Date.UTC(2011, 9, 18, 15, 52, 35, 929),
               parseRFC3339Date("2011-10-18T15:52:35.928687640Z").valueOf());

  assertEquals(Date.UTC(2011, 9, 18, 15, 52, 35, 929),
               parseRFC3339Date("2011-10-18T15:52:35.928687640z").valueOf());

  assertEquals(Date.UTC(2011, 9, 18, 15, 52, 35, 929),
               parseRFC3339Date("2011-10-18T15:52:35.928687640").valueOf());

  assertEquals(Date.UTC(2011, 9, 18, 15, 52, 35, 0),
               parseRFC3339Date("2011-10-18T15:52:35").valueOf());

  assertEquals(Date.UTC(2011, 9, 18, 15, 52, 35, 0),
               parseRFC3339Date("2011-10-18T15:52:35Z").valueOf());

  assertEquals(Date.UTC(2011, 9, 18, 15, 55, 13, 143),
               parseRFC3339Date("2011-10-18 18:55:13.142337777+03:00").valueOf());

  // root@pi:~# date -u -d '2011-10-18 18:55:13.142337777+01:30'
  // Tue Oct 18 17:25:13 UTC 2011
  assertEquals(Date.UTC(2011, 9, 18, 17, 25, 13, 143),
               parseRFC3339Date("2011-10-18 18:55:13.142337777+01:30").valueOf());

  // root@pi:~# date -u -d '2011-10-18 18:55:13.142337777-01:30'
  // Tue Oct 18 20:25:13 UTC 2011
  assertEquals(Date.UTC(2011, 9, 18, 20, 25, 13, 143),
               parseRFC3339Date("2011-10-18 18:55:13.142337777-01:30").valueOf());

  // root@pi:~# date -u -d '2011-10-18 18:55:13.142337777-00:30'
  // Tue Oct 18 19:25:13 UTC 2011
  assertEquals(Date.UTC(2011, 9, 18, 19, 25, 13, 143),
               parseRFC3339Date("2011-10-18 18:55:13.142337777-00:30").valueOf());

  assertEquals(Date.UTC(2011, 9, 18, 15, 55, 13, 142),
               parseRFC3339Date("2011-10-18 18:55:13.142+03:00").valueOf());

  assertEquals(Date.UTC(2011, 9, 18, 15, 52, 47, 327),
               parseRFC3339Date("2011-10-18 08:52:47.326164498-07:00").valueOf());
};

var NaturalSortTest = TestCase("NaturalSortTest");
NaturalSortTest.prototype.testHostnameSorting = function() {
  var ips = [{'hostname':'10.2.34.5'},
             {'hostname':'1.2.3.4'},
             {'hostname':'10.2.34.10'},
             {'hostname':'cb.example.com:9002'},
             {'hostname':'cb.example.com'},
             {'hostname':'cb.example.com:9001'},
             {'hostname':'cb.couchbase.com'}];
  var sorted = [ {'hostname':'1.2.3.4'},
                 {'hostname':'10.2.34.5'},
                 {'hostname':'10.2.34.10'},
                 {'hostname':'cb.couchbase.com'},
                 {'hostname':'cb.example.com'},
                 {'hostname':'cb.example.com:9001'},
                 {'hostname':'cb.example.com:9002'}];
  assertEquals(sorted, ips.sort(mkComparatorByProp('hostname', naturalSort)));
};