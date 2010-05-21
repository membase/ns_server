function BinaryHeap(lessOp) {
  this.elements = [];
  this.lessOp = lessOp;
}

BinaryHeap.stdLess = function (a, b) {
  return a < b;
}

BinaryHeap.prototype.add = function (item) {
  this.pushHoleUp(item, this.elements.length);
}

BinaryHeap.prototype.popLeast = function () {
  var rv = this.elements[0];
  var replacement = this.elements.pop();
  // if rv is not last element than push replacement into hole from
  // zero element (rv)
  if (this.elements.length > 0) {
    this.pushHoleDown(replacement, 0);
  }
  return rv;
}

BinaryHeap.prototype.getSize = function () {
  return this.elements.length;
}

BinaryHeap.prototype.isEmpty = function () {
  return this.elements.length == 0;
}

BinaryHeap.prototype.pushHoleUp = function (e, hole) {
  while (hole > 0) {
    var parent = (hole-1) >> 1;
    var parentElement = this.elements[parent];
    if (!this.lessOp(e, parentElement)) {
      break;
    }

    this.elements[hole] = parentElement;
    hole = parent;
  }

  this.elements[hole] = e;
  return hole;
}

BinaryHeap.prototype.pushHoleDown = function (e, hole) {
  var child = hole*2 + 2;
  var size = this.elements.length;
  // child holds rightmost child
  while (child < size) {
    var childElement = this.elements[child];
    var firstChild = this.elements[child-1];
    // if rightmost child is bigger than it's left brother, consider it's left brother
    if (this.lessOp(firstChild, childElement)) {
      childElement = firstChild;
      child--;
    }
    // if we can place our element into hole, stop process
    if (!this.lessOp(childElement, e)) {
      break;
    }
    // place child into hole, moving hole into it's position
    this.elements[hole] = childElement;
    hole = child;
    // get new rightmost child index
    child = hole*2+2;
  }
  // if last hole have only one child (leftmost)
  if (child == size) {
    child--;
    var childElement = this.elements[child];
    // check if this child must be moved into hole
    if (this.lessOp(childElement, e)) {
      this.elements[hole] = childElement;
      hole = child;
    }
  }
  this.elements[hole] = e;
  return hole;
}

BinaryHeap.prototype.clear = function () {
  this.elements.length = 0;
}
