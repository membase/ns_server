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

var sampleDocs = [{
   "_id": "234235124",
   "_rev": "3-12342341234",
   "type": "event",
   "title": "meeting",
   "where": "coffee bar",
   "hosts": [
       "benjamin@couchbase.com"
   ]
},
{
  "_id": "0594680c9ba809979a8e5f9a8000027c",
  "_rev": "3-7f43cdfce1b537739736a97c4eb78d62",
  "created_at": "2010-07-04T18:06:34.020Z",
  "profile": {
      "rand": "0.8309284392744303",
      "email": "jchris@couch.io",
      "url": "http://jchrisa.net",
      "gravatar_url": "http://www.gravatar.com/avatar/6f09a637f926f04d9b34bfe10e94bd3e.jpg?s=40&d=identicon",
      "name": "jchris"
  },
  "message": "refactor #focus evently.nav so it is properly bound to login and logout status",
  "state": "done",
  "publish": true,
  "type": "task",
  "edit_at": "2010-07-11T22:08:52.928Z",
  "edit_by": "jchris"
},
{
  "_id": "1643684c68d03fb70bc98d88a8896d0d",
  "_rev": "6-ff271e27fd0edfd88afb1d16e1363f79",
  "urls": {
      "@doppler": "http://twitter.com/doppler",
      "Web Developer, SXSW": "http://sxsw.com",
      "github.com/doppler": "http://github.com/doppler"
  },
  "bio": "I've been playing with and using CouchDB since version 0.9.0, sometime in early 2009. The first real app I created on CouchDB was to solve the problem of needing to provide an API to query SXSW schedule data, to be used by a 3rd-party developer creating an iPhone app. I'm hoping to build on that idea for SXSW 2011.",
  "hometown": "Austin, TX",
  "name": "David Rose",
  "_attachments": {
      "Photo on 2010-09-10 at 14.44.jpg": {
          "content_type": "image/jpeg",
          "revpos": 5,
          "digest": "md5-dlyF/44110seO+xxDgrkHA==",
          "length": 79027,
          "stub": true
      }
  }
}];

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
};

var ViewDevSection = {
  init: function() {
    $('#built_in_reducers a').click(function(ev) {
      $('#viewcode_reduce').text($(ev.target).text());
    });

    $('#preview_random_doc').click(function(ev) {
      ev.stopPropagation();
      var jq = $('#sample_docs pre');
      var u = 2;
      var l = 0;
      var rand = Math.floor((Math.random() * (u-l+1))+l);
      jq.html($.futon.formatJSON(sampleDocs[rand], {html: true}));

      if (jq.closest('.graph_nav').hasClass('closed')) {
        jq.closest('.graph_nav').removeClass('closed');
      }
    }).trigger('click');
  },
  onEnter: function () {
  },
  navClick: function () {
  }
};
