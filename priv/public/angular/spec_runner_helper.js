var specRunnerHelper = {};

specRunnerHelper.MockedPromise = function (response) {
  this.switchOn('success').setResponse(response);
};
specRunnerHelper.MockedPromise.prototype.setResponse = function () {
  this.responseArgs = Array.prototype.slice.call(arguments, 0);
  return this;
};
specRunnerHelper.MockedPromise.prototype.switchOn = function (switchOn) {
  if (switchOn === 'error') {
    this.error = this.resolve;
    this.success = this.blank;
  } else {
    this.error = this.blank;
    this.success = this.resolve;
  }
  return this;
};
specRunnerHelper.MockedPromise.prototype.finally = function (callback) {
  callback.apply(this, this.responseArgs);
  return this;
}
specRunnerHelper.MockedPromise.prototype.resolve = function (callback) {
  callback.apply(this, this.responseArgs);
  return this;
};
specRunnerHelper.MockedPromise.prototype.blank = function (callback) {
  return this;
};

specRunnerHelper.Counter = function () {}
specRunnerHelper.Counter.prototype.counter = 0;
specRunnerHelper.Counter.prototype.increment = function () {
  return this.counter++;
};

specRunnerHelper.MockedForm = function () {};
specRunnerHelper.MockedForm.prototype.$setValidity = function () {};
specRunnerHelper.MockedForm.prototype.$invalid = false;