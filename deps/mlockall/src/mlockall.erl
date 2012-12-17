%% @author Couchbase <info@couchbase.com>
%% @copyright 2012 Couchbase, Inc.
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

-module(mlockall).

-export([lock/1, unlock/0]).

-ifdef(HAVE_MLOCKALL).

-on_load(init/0).

init() ->
    SoName = case code:priv_dir(?MODULE) of
                 {error, bad_name} ->
                     case filelib:is_dir(filename:join(["..", "priv"])) of
                         true ->
                             filename:join(["..", "priv", "mlockall_nif"]);
                         false ->
                             filename:join(["priv", "mlockall_nif"])
                     end;
                 Dir ->
                     filename:join(Dir, "mlockall_nif")
             end,
    erlang:load_nif(SoName, 0),
    case erlang:system_info(otp_release) of
        "R13B03" ->
            true;
        _ ->
            ok
    end.

lock(_Flags) ->
    erlang:nif_error(mlockall_nif_not_loaded).

unlock() ->
    erlang:nif_error(mlockall_nif_not_loaded).

-else.                                          % -ifndef(WIN32)

lock(_Flags) ->
    {error, enotsup}.

unlock() ->
    {error, enotsup}.

-endif.
