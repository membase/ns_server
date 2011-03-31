
var mkClassTest = TestCase("mkClassTest");

mkClassTest.prototype.testBasic = function () {
  var proto = {
    foo: function () {
      return "foo";
    },
    bar: "bar"
  };
  var klass = mkClass(proto);

  assert(klass instanceof Function);
  assertEquals(Function, klass.constructor);
  assert('foo' in klass.prototype);
  assert('bar' in klass.prototype);

  var completeProto = _.extend({
    constructor: klass
  }, proto);
  // In cursed browser dontEnum properties are not enumerable even if
  // re-defined in descendant object
  if (_.include(_.keys(completeProto), "constructor")) {
    console.log("not ie");
    assertEquals(klass.prototype, completeProto);
    assertNotEquals(klass.prototype, proto);
  } else {
    assertEquals(klass.prototype, completeProto);
    assertEquals(klass.prototype, proto);
  }

  var obj = new klass();

  assert(obj instanceof klass);
  assertEquals(klass, obj.constructor);

  assertEquals(proto.foo, obj.foo);
  assertEquals(proto.bar, obj.bar);
}

mkClassTest.prototype.testInheritance = function () {
  var A = mkClass({
    foo: function () {
      return "foo";
    },
    bar: function () {
      return "bar";
    },
    constant: 3.141592
  });

  var B = mkClass(A, {
    foo: function ($super) {
      return "B" + $super();
    }
  });

  var b = new B();

  assertEquals("bar", b.bar());
  assertEquals("Bfoo", b.foo());
  assertEquals("foo", (new A()).foo());

  assertEquals(3.141592, b.constant);
}

mkClassTest.prototype.testInitialize = function () {
  var A = mkClass({
    initialize: function (a,b,c) {
      this.data = [a,b,c];
    }
  });
  var B = mkClass(A, {
    initialize: function ($super,a,b,c) {
      $super(a,b,c);
      // if constructor returns Object, than 'this' is discarded and
      // that object is returned from new. As per EcmaScript spec
      return {originalThis: this};
    }
  });

  var a = new A(1,2,3);
  assert(_.isEqual([1,2,3], a.data));

  var b = new B(1,2,3);
  assert(!(b instanceof B));
  assert(b.originalThis instanceof B);
  assert(_.isEqual([1,2,3], b.originalThis.data));
}
