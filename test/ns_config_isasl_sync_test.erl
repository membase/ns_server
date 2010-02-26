-module(ns_config_isasl_sync_test).

-export([test/0]).

% This is copied from the code under test.  If something isn't working
% right, it's probably because this fell out of sync.
%
% Of course, an alternative would either be making an include file or
% exposing some functionality over there specifically for testing, but
% I'd prefer to keep things a bit cleaner from an API point of view at
% what I believe to be a small cost in test maintainability.  If I'm
% wrong, we'll fix it.
-record(state, {buckets, path, updates, admin_user, admin_pass}).

test() ->
    test_parsing(),
    test_writing().

test_parsing() ->
    Expected = [
                {"other_application", [{auth_plain, {"other_application", "another_password"}},
                                       {size_per_node, 64}
                                      ]},
                {"test_application", [{auth_plain, {"test_application", "plain_text_password"}},
                                      {size_per_node, 64}
                                     ]}],
    Expected = ns_config_isasl_sync:extract_creds(sample_config()).

test_writing() ->
    Path = "isasl_test.db",
    FullPath = filename:join("priv", Path),
    % {ok, State, hibernate} = ns_config_isasl_sync:init(Path),
    State = #state{updates=0, path=Path, buckets=[],
                  admin_user="admin", admin_pass="admin"},
    0 = State#state.updates,

    % First update should cause data to be written.
    {ok, State2, hibernate} = ns_config_isasl_sync:handle_event(
                                 {pools, sample_config()}, State),
    Expected = [
                "admin admin\n",
                "other_application another_password\n",
                "test_application plain_text_password\n"],
    {ok, F} = file:open(FullPath, [read]),
    lists:foreach(fun (E) -> E = io:get_line(F, "") end, Expected),
    file:close(F),
    ok = file:delete(FullPath),
    1 = State2#state.updates,

    % another update should not cause data to be written.
    {ok, State3, hibernate} = ns_config_isasl_sync:handle_event(
                                {pools, sample_config()}, State2),
    1 = State3#state.updates.

sample_config() ->
    [
     {"default", [
                  {address, "0.0.0.0"}, % An IP binding
                  {port, 11211},
                  {buckets, [
                             {"default", [{auth_plain, undefined},
                                          {size_per_node, 64}
                                         ]},
                             {"test_application", [{auth_plain, {"test_application", "plain_text_password"}},
                                                   {size_per_node, 64}
                                                  ]},
                             {"other_application", [{auth_plain, {"other_application", "another_password"}},
                                                    {size_per_node, 64}
                                                   ]}
                            ]}
                 ]}
    ].
