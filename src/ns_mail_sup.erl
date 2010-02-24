% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_mail_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

start_link() ->
    supervisor:start_link({global, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_all,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
           [{ns_mail, {ns_mail, start_link, []},
             permanent, 10, worker, [ns_mail, gen_smtp_client]},
            {ns_mail_log, {ns_mail_log, start_link, []},
             transient, 10, worker, []}
           ]}}.
