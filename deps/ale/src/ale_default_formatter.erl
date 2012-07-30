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

-module(ale_default_formatter).

%% API
-export([format_msg/2]).

-include("ale.hrl").

format_msg(#log_info{logger=Logger,
                     loglevel=LogLevel,
                     module=M, function=F, line=L,
                     time=Time, process=Process, node=Node} = _Info, UserMsg) ->
    {{Year, Month, Day}, {Hour, Minute, Second}} =
        calendar:now_to_local_time(Time),
    Millis = erlang:element(3, Time) div 1000,
    Header =
        io_lib:format("[~s:~s,"
                      "~B-~2.10.0B-~2.10.0BT~B:~2.10.0B:~2.10.0B.~3.10.0B,"
                      "~s:~p:~s:~s:~B]",
                      [Logger, LogLevel,
                       Year, Month, Day, Hour, Minute, Second, Millis,
                       Node, Process, M, F, L]),
    [Header, UserMsg, "\n"].
