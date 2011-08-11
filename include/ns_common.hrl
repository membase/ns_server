%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
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
%% @doc Macros used all over the place.
%%

-type bucket_name() :: nonempty_string().
-type bucket_type() :: memcached | membase.
-type histogram() :: [{atom(), non_neg_integer()}].
-type map() :: [[atom(), ...], ...].
-type mc_error_atom() :: key_enoent | key_eexists | e2big | einval |
                         not_stored | delta_badval | not_my_vbucket |
                         unknown_command | enomem | not_supported | internal |
                         ebusy.
-type mc_error() :: {memcached_error, mc_error_atom(), binary()}.
-type moves() :: [{non_neg_integer(), atom(), atom()}].
-type vbucket_id() :: non_neg_integer().
-type vbucket_state() :: active | dead | replica | pending.

-type version() :: {list(integer()), candidate | release, integer()}.

-define(MULTICALL_DEFAULT_TIMEOUT, 30000).

-define(LOG(Fun, Format, Args),
        error_logger:Fun("~s:~p:~s:~B: " ++ Format ++ "~n",
                         [node(), self(), ?MODULE, ?LINE] ++ Args)).

-define(log_info(Format, Args), ?LOG(info_msg, Format, Args)).
-define(log_info(Msg), ?log_info(Msg, [])).

-define(log_warning(Format, Args), ?LOG(warning_msg, Format, Args)).
-define(log_warning(Msg), ?log_warning(Msg, [])).

-define(log_error(Format, Args), ?LOG(error_msg, Format, Args)).
-define(log_error(Msg), ?log_error(Msg, [])).
