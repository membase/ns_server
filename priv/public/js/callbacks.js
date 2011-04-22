/**
   Copyright 2011 Couchbase, Inc.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
 **/
var Slave = mkClass({
  initialize: function (thunk) {
    this.thunk = thunk
  },
  die: function () {this.dead = true;},
  nMoreTimes: function (times) {
    this.times = this.times || 0;
    this.times += times;
    var oldThunk = this.thunk;
    this.thunk = function (data) {
      oldThunk.call(this, data);
      if (--this.times == 0)
        this.die();
    }
    return this;
  }
});

var CallbackSlot = mkClass({
  initialize: function () {
    this.slaves = [];
    this.broadcasting = 0;
  },
  subscribeWithSlave: function (thunkOrSlave) {
    var slave;
    if (thunkOrSlave instanceof Slave)
      slave = thunkOrSlave;
    else
      slave = new Slave(thunkOrSlave);
    var wasEmpty = (this.slaves.length == 0);
    this.slaves.push(slave);
    if (wasEmpty)
      this.__demandChanged(true);
    return slave;
  },
  subscribeOnce: function (thunk) {
    return this.subscribeWithSlave(thunk).nMoreTimes(1);
  },
  broadcast: function (data) {
    this.broadcasting++;
    _.each(this.slaves, function (slave) {
      if (slave.dead)
        return;
      try {
        slave.thunk(data);
      } catch (e) {
        console.log("got exception in CallbackSlot#broadcast", e, "for slave thunk", slave.thunk);
        slave.die();
        _.defer(function () {throw e;});
      }
    });
    this.broadcasting--;
    this.cleanup();
  },
  unsubscribeCallback: function (thunk) {
    var slave = _.detect(this.slaves, function (candidate) {
      return candidate.thunk == thunk;
    });
    if (slave)
      this.unsubscribe(slave);
    return slave;
  },
  unsubscribe: function (slave) {
    slave.die();
    if (this.broadcasting)
      return;
    var index = $.inArray(slave, this.slaves);
    if (index >= 0) {
      this.slaves.splice(index, 1);
      if (!this.slaves.length)
        this.__demandChanged(false);
    }
  },
  cleanup: function () {
    if (this.broadcasting)
      return;
    var oldLength = this.slaves.length;
    this.slaves = _.reject(this.slaves, function (slave) {return slave.dead;});
    if (oldLength && !this.slaves.length)
      this.__demandChanged(false);
  },
  __demandChanged: function (haveDemand) {
  }
});
