
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