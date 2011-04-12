
WrappedDateTest = TestCase("WrappedDateTest");

WrappedDateTest.prototype.testBasic = function () {
  var WrappedDate = mkDateWrapper();

  var wd = new WrappedDate(2010, 3, 14, 15, 26, 45, 789);

  assert(wd instanceof WrappedDate);
  assert(!(wd instanceof Date));
  assertEquals(WrappedDate, wd.constructor);

  assertEquals(2010, wd.getFullYear());
  assertEquals(3, wd.getMonth());
  assertEquals(14, wd.getDate());
  assertEquals(15, wd.getHours());
  assertEquals(26, wd.getMinutes());
  assertEquals(45, wd.getSeconds());
  assertEquals(789, wd.getMilliseconds());

  wd.setHours(13, 0, 0, 0);

  assertEquals(2010, wd.getFullYear());
  assertEquals(3, wd.getMonth());
  assertEquals(14, wd.getDate());
  assertEquals(13, wd.getHours());
  assertEquals(0, wd.getMinutes());
  assertEquals(0, wd.getSeconds());
  assertEquals(0, wd.getMilliseconds());

  assertEquals(2010, wd.getUTCFullYear());
  assertEquals(3, wd.getUTCMonth());

  assertEquals(wd._original.valueOf(), wd.valueOf());
  assertEquals(wd._original.getTimezoneOffset(), wd.getTimezoneOffset());
  assertEquals(wd._original.toUTCString(), wd.toUTCString());

  var d = new Date();
  d.setMilliseconds(0);
  assertEquals(Date.parse(d.toString()), d.valueOf());
  assertEquals(WrappedDate.parse(d.toString()), d.valueOf());

  assertEquals(WrappedDate.UTC(2010, 3, 14, 13, 26, 45, 879),
               Date.UTC(2010, 3, 14, 13, 26, 45, 879));
}

function mockDateNow(methods, NewDate) {
  var originalInitialize = methods.initialize;

  methods.initialize = function (originalDate, args) {
    if (args.length == 0) {
      return originalInitialize.call(this, originalDate, [NewDate.now]);
    }
    return originalInitialize.call(this, originalDate, args);
  }
}

function mkMockedDateNow(now) {
  if (now instanceof Date) {
    now = now.valueOf();
  }
  now = Number(now);

  var rv = mkDateWrapper(mockDateNow);
  rv.now = now;
  return rv;
}

WrappedDateTest.prototype.testMockedNow = function () {
  var mockedNow = new Date(Date.UTC(2010, 1, 14, 13, 30));
  var MockedDate = mkMockedDateNow(mockedNow);

  assertEquals(mockedNow.toString(), MockedDate());
  assertEquals(mockedNow.valueOf(), (new MockedDate()).valueOf());

  assertEquals(Date.UTC(2010, 1, 14, 13, 30), (new MockedDate()).valueOf());
  MockedDate.now += 3600*1000;
  assertEquals(Date.UTC(2010, 1, 14, 14, 30), (new MockedDate()).valueOf());
}
