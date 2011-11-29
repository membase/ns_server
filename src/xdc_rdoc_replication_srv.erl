%% @author Couchbase <info@couchbase.com>
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

-module(xdc_rdoc_replication_srv).
-include("couch_db.hrl").

-export([start_link/0, update_doc/1]).

-behaviour(cb_generic_replication_srv).
-export([server_name/1, init/1, get_remote_nodes/1,
         load_local_docs/2, open_local_db/1]).


update_doc(Doc) ->
    gen_server:call({local, server_name(ok)},
                    {interactive_update, Doc}, infinity).


start_link() ->
    cb_generic_replication_srv:start_link(?MODULE, []).


%% Callbacks
server_name(_) ->
    ?MODULE.


init(_) ->
    {ok, ok}.


get_remote_nodes(_) ->
    ns_node_disco:nodes_wanted() -- [node()].


load_local_docs(Db, _) ->
    {ok,_, Docs} = couch_db:enum_docs(
                     Db,
                     fun(DocInfo, _Reds, AccDocs) ->
                             {ok, Doc} = couch_db:open_doc_int(Db, DocInfo, []),
                             {ok, [Doc | AccDocs]}
                     end,
                     [], []),
    {ok, Docs}.


open_local_db(_) ->
    case couch_db:open(<<"_replicator">>, []) of
        {ok, Db} ->
            {ok, Db};
        {not_found, _} ->
            couch_db:create(<<"_replicator">>, [])
    end.
