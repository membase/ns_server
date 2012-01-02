%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(capi_http_proxy).

-include("couch_db.hrl").

-export([handle_proxy_req/1]).

handle_proxy_req(MochiReq) ->
    DefaultSpec = "{couch_httpd_db, handle_request}",
    DefaultFun = couch_httpd:make_arity_1_fun(
                   couch_config:get("httpd", "default_handler", DefaultSpec)
                  ),

    UrlHandlersList = lists:map(
                        fun({UrlKey, SpecStr}) ->
                                {?l2b(UrlKey), couch_httpd:make_arity_1_fun(SpecStr)}
                        end, couch_config:get("httpd_global_handlers")),

    DbUrlHandlersList = lists:map(
                          fun({UrlKey, SpecStr}) ->
                                  {?l2b(UrlKey), couch_httpd:make_arity_2_fun(SpecStr)}
                          end, couch_config:get("httpd_db_handlers")),

    DesignUrlHandlersList = lists:map(
                              fun({UrlKey, SpecStr}) ->
                                      {?l2b(UrlKey), couch_httpd:make_arity_3_fun(SpecStr)}
                              end, couch_config:get("httpd_design_handlers")),

    UrlHandlers = dict:from_list(UrlHandlersList),
    DbUrlHandlers = dict:from_list(DbUrlHandlersList),
    DesignUrlHandlers = dict:from_list(DesignUrlHandlersList),

    DbFrontendModule = list_to_atom(couch_config:get("httpd", "db_frontend", "couch_db_frontend")),

    "/" ++ RawPath = MochiReq:get(raw_path),

    CutRawPath = lists:dropwhile(fun ($/) -> false;
                                     (_) -> true
                                 end, RawPath),

    NewMochiReq = mochiweb_request:new(MochiReq:get(socket),
                                       MochiReq:get(method),
                                       CutRawPath,
                                       MochiReq:get(version),
                                       MochiReq:get(headers)),

    couch_httpd:handle_request(NewMochiReq, DbFrontendModule,
                               DefaultFun, UrlHandlers,
                               DbUrlHandlers, DesignUrlHandlers).
