%% @author Couchbase <info@couchbase.com>
%% @copyright 2017 Couchbase, Inc.
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
%% Retransmission timeout estimation roughly following
%% https://tools.ietf.org/html/rfc6298.
-module(rto).

-export_type([rto/0]).

-export([new/1, get_timeout/1, get_rtt_estimate/1]).
-export([note_success/2, note_failure/1]).

-include("cut.hrl").

-record(rto, { rtt     :: moving_average:moving_average(),
               rtt_var :: moving_average:moving_average(),
               timeout :: pos_integer(),
               backoff :: undefined | backoff:backoff(),

               min_timeout :: pos_integer(),
               max_timeout :: pos_integer(),

               backoff_multiplier :: float(),
               var_multiplier     :: integer() }).

-type rto() :: #rto{}.

new(Props) ->
    {window, Window}          = lists:keyfind(window, 1, Props),
    {backoff, Backoff}        = lists:keyfind(backoff, 1, Props),
    {min_timeout, MinTimeout} = lists:keyfind(min_timeout, 1, Props),
    {max_timeout, MaxTimeout} = lists:keyfind(max_timeout, 1, Props),
    {var_multiplier, VarMult} = lists:keyfind(var_multiplier, 1, Props),

    #rto{rtt                = moving_average:new(Window),
         rtt_var            = moving_average:new(Window),
         timeout            = MinTimeout,
         backoff            = undefined,

         min_timeout        = MinTimeout,
         max_timeout        = MaxTimeout,

         backoff_multiplier = Backoff,
         var_multiplier     = VarMult}.

get_rtt_estimate(#rto{rtt     = RttAvg,
                      rtt_var = RttVarAvg}) ->
    {moving_average:get_estimate(RttAvg),
     moving_average:get_estimate(RttVarAvg)}.

get_timeout(#rto{backoff = undefined,
                 timeout = Timeout}) ->
    Timeout;
get_timeout(#rto{backoff = Backoff}) ->
    backoff:get_timeout(Backoff).

note_success(Time, Rto) ->
    functools:chain(Rto,
                    [maybe_remove_backoff(_),
                     update_estimates(Time, _),
                     update_timeout(_)]).

note_failure(Rto) ->
    functools:chain(Rto,
                    [maybe_add_backoff(_),
                     misc:update_field(#rto.backoff, Rto, backoff:next(_))]).

%% internal
maybe_add_backoff(#rto{backoff            = undefined,
                       timeout            = Timeout,
                       max_timeout        = MaxTimout,
                       backoff_multiplier = Multiplier} = Rto) ->
    Backoff = backoff:new([{initial, Timeout},
                           {multiplier, Multiplier},
                           {threshold, MaxTimout}]),
    Rto#rto{backoff = Backoff};
maybe_add_backoff(Rto) ->
    Rto.

update_estimates(ObservedRtt, #rto{rtt     = RttAvg,
                                   rtt_var = RttVarAvg} = Rto) ->
    Ts = time_compat:monotonic_time(millisecond),

    RttError =
        case moving_average:get_estimate(RttAvg) of
            empty ->
                ObservedRtt / 2;
            ExpectedRtt ->
                abs(ObservedRtt - ExpectedRtt)
        end,

    NewRttAvg    = moving_average:feed(ObservedRtt, Ts, RttAvg),
    NewRttVarAvg = moving_average:feed(RttError, Ts, RttVarAvg),

    Rto#rto{rtt     = NewRttAvg,
            rtt_var = NewRttVarAvg}.

update_timeout(#rto{rtt            = RttAvg,
                    rtt_var        = RttVarAvg,
                    min_timeout    = MinTimeout,
                    var_multiplier = VarMult} = Rto) ->
    Rtt     = moving_average:get_estimate(RttAvg),
    RttVar  = moving_average:get_estimate(RttVarAvg),
    Timeout = Rtt + max(MinTimeout, VarMult * RttVar),

    Rto#rto{timeout = trunc(Timeout)}.

maybe_remove_backoff(#rto{backoff = undefined} = Rto) ->
    Rto;
maybe_remove_backoff(Rto) ->
    Rto#rto{backoff = undefined}.
