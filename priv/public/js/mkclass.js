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
function mkMethodWrapper (method, superClass, methodName) {
  return function () {
    var args = $.makeArray(arguments);
    var _super = $m(this, methodName, superClass);
    args.unshift(_super);
    return method.apply(this, args);
  };
}

function mkClass(methods) {
  if (_.isFunction(methods)) {
    var superclass = methods;
    var origMethods = arguments[1];

    var meta = function() {};
    meta.prototype = superclass.prototype;

    methods = _.extend(new meta(), origMethods);

    _.each(origMethods, function (method, methodName) {
      if (_.isFunction(method) && functionArgumentNames(method)[0] === '$super') {
        methods[methodName] = mkMethodWrapper(method, superclass, methodName);
      }
    });
  } else {
    methods = _.extend({}, methods);
  }

  var constructor = function () {
      if (this.initialize) {
        return this.initialize.apply(this, arguments);
      }
    };

  methods.constructor = constructor;
  constructor.prototype = methods;

  return constructor;
}
