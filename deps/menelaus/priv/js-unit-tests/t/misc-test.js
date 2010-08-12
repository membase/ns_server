
var DecimationTest = TestCase("DecimationTest");

DecimationTest.prototype.testCutoff = function () {
  var samples = new Array(100);
  var i = 0;
  for (i=0;i<samples.length;i++) {
    samples[i] = (i & 1) ? 1 : 0;
  }

  var outSamples = decimateSamples(2, samples);

  var avg = _.reduce(outSamples, 0, function (acc, s) {return acc + s})/outSamples.length;

  var min = Math.min.apply(null, outSamples);
  var max = Math.max.apply(null, outSamples);

  // we test that our filter has nearly completely killed high-freq
  // component
  assertTrue(Math.abs(avg - min) < 0.01);
  assertTrue(Math.abs(avg - max) < 0.01);
}
