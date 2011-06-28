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
// from CouchDB URL: /{db}/_all_docs?startkey="_design/"&endkey="_design0"&include_docs=true
var sampleViewsData = {"total_rows":20,"offset":12,"rows":[
  { "id":"_design/adhoc",
    "key":"_design/adhoc",
    "value":{"rev":"13-ea509c85ed1fe2102632de72b5de4043"},
    "doc":{
      "_id":"_design/adhoc",
      "_rev":"13-ea509c85ed1fe2102632de72b5de4043",
      "language":"javascript",
      "views":{
        "query":{
          "map":"function(doc) {\n  for (var k in doc) {\n    if (k.substr(0,1) !== '_') {\n      emit(doc[k], {\"_id\": doc._id, \"path\": k});\n    }\n  }\n}"
        }
      }
    }
  },
  { "id":"_design/TeaTime",
    "key":"_design/TeaTime",
    "value":{"rev":"1-5ade2e707ee6f3b2d4467ff5e8f2a96a"},
    "doc":{
      "_id":"_design/TeaTime",
      "_rev":"1-5ade2e707ee6f3b2d4467ff5e8f2a96a",
      "language": "javascript",
      "views":{
        "all_users":{
          "map":"function(doc) {\n  function emitUsers(users) {\n    if (users && users.forEach) {\n      users.forEach(function(user) {\n        emit(user, 1);\n      });\n    }\n  }\n  if (doc.type == \"event\") {\n        emitUsers(doc.attendees);\n        emitUsers(doc.hosts);\n  }\n  if (doc.type == \"profile\") {\n        emitUsers(doc, doc.attendees, doc.start && doc.end);\n  }\n};",
          "reduce":"_count"
        },
        "by_user_date":{
          "map":"function(doc) {\n  function emitUsersMonthly(doc, users, start, end) {\n    if (users && users.forEach) {\n      users.forEach(function(user) {\n        emitUserMonthly(doc, user, doc.start, doc.end);\n      });\n    }\n  }\n  function emitUserMonthly(doc, user, start, end) {\n    var totalEmitted = 0;\n    while (totalEmitted++ < 36 && start <= end) {\n      var d = new Date(start);\n      emit([user, d.getFullYear(), d.getMonth()], doc);\n      if (d.getMonth() == 11) {\n        d.setFullYear(d.getFullYear() + 1);\n        d.setMonth(0);\n      } else {\n        d.setMonth(d.getMonth() + 1);\n      }\n      start = d.getTime();\n    }\n  }\n  if (doc.type == \"event\" && doc.start && doc.end\n      && typeof doc.start == \"number\" && typeof doc.end == \"number\") {\n        emitUsersMonthly(doc, doc.attendees, doc.start && doc.end);\n        emitUsersMonthly(doc, doc.hosts, doc.start && doc.end);\n  }\n};"
        }
      }
    }
  }
]};

var ViewsSection = {
  init: function () {
    var self = this;

    self.tabs = new TabsCell("viewsTab",
                             "#views .tabs",
                             "#views .panes > div",
                             ["production", "development"]);

    renderTemplate('views_list', {rows: sampleViewsData.rows}, $i('production_views_list_container'));
    renderTemplate('views_list', {rows: _.reject(sampleViewsData.rows, function(row) {
      return row.id === '_design/adhoc';
    })}, $i('development_views_list_container'));
  },
  onEnter: function () {
  },
  navClick: function () {
  }
}