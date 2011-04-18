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
%%
%% @doc Find windows nameservers

-module(win32dns).

-include("ns_common.hrl").

-export([win32_dns_setup/0]).

-define(IFPARMS, "\\hklm\\system\\CurrentControlSet\\Services\\TcpIp\\Parameters\\Interfaces").

get_ns(R, Interface) ->
    win32reg:change_key(R, ?IFPARMS ++ "\\" ++ Interface),
    case win32reg:value(R, "NameServer") of
        {ok, Value} ->
            {ok, Value};
        _ ->
            undefined
    end.

ns_list(R) ->
    win32reg:change_key(R, ?IFPARMS),
    {ok, Interfaces} = win32reg:sub_keys(R),
    [NS || {ok, NS} <- [get_ns(R, I) || I <- Interfaces]].

do_win32_dns_setup() ->
    {ok, R} = win32reg:open([read]),
    [inet_db:add_ns(NS) || NS <-
        [list_to_tuple([list_to_integer(N) || N <- string:tokens(IP, ".")]) || IP <- ns_list(R)]],
    win32reg:close(R).

win32_dns_setup() ->
    try do_win32_dns_setup() of
        ok ->
            ok
    catch
        T:E ->
            ?log_warning("Failed to set up windows nameservers: ~p~n", [{T,E}]),
            error
    end.
