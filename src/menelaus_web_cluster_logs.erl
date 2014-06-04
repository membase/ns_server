%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc.
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
-module(menelaus_web_cluster_logs).

-export([handle_start_collect_logs/1, handle_cancel_collect_logs/1]).

handle_start_collect_logs(Req) ->
    Params = Req:parse_post(),

    case parse_validate_collect_params(Params, ns_config:get()) of
        {ok, Nodes, BaseURL} ->
            case cluster_logs_collection_task:preflight_base_url(BaseURL) of
                ok ->
                    case cluster_logs_sup:start_collect_logs(Nodes, BaseURL) of
                        ok ->
                            menelaus_util:reply_json(Req, [], 200);
                        already_started ->
                            menelaus_util:reply_json(Req, {struct, [{'_', <<"Logs collection task is already started">>}]}, 400)
                    end;
                {error, Message} ->
                    menelaus_util:reply_json(Req, {struct, [{'_', Message}]}, 400)
            end;
        {errors, RawErrors} ->
            Errors = [case stringify_one_node_upload_error(E) of
                          {Field, Msg} ->
                              {Field, iolist_to_binary([Msg])};
                          List -> List
                      end || E <- RawErrors],
            menelaus_util:reply_json(Req, {struct, lists:flatten(Errors)}, 400)
    end.

%% we're merely best-effort-sync and we don't care about results
handle_cancel_collect_logs(Req) ->
    cluster_logs_sup:cancel_logs_collection(),
    menelaus_util:reply_json(Req, []).

stringify_one_node_upload_error({unknown_nodes, List}) ->
    {nodes, io_lib:format("Unknown nodes: ~p", [List])};
stringify_one_node_upload_error(missing_nodes) ->
    {nodes, <<"must be given">>};
stringify_one_node_upload_error({empty, F}) ->
    {F, <<"cannot be empty">>};
stringify_one_node_upload_error({malformed, F}) ->
    {F, <<"must not contain /">>};
stringify_one_node_upload_error(missing_customer) ->
    [{customer, <<"customer must be given if upload host or ticket is given">>}];
stringify_one_node_upload_error(missing_upload) ->
    [{uploadHost, <<"upload host must be given if customer or ticket is given">>}].

parse_nodes("*", Config) ->
    {ok, ns_node_disco:nodes_wanted(Config)};
parse_nodes(undefined, _) ->
    {error, missing_nodes};
parse_nodes(NodesParam, Config) ->
    KnownNodes = sets:from_list([atom_to_list(N) || N <- ns_node_disco:nodes_wanted(Config)]),
    Nodes = string:tokens(NodesParam, ","),
    {_Good, Bad} = lists:partition(
                    fun (N) ->
                            sets:is_element(N, KnownNodes)
                    end, Nodes),
    case Bad of
        [] ->
            {ok, lists:usort([list_to_atom(N) || N <- Nodes])};
        _ ->
            {error, {unknown_nodes, Bad}}
    end.

parse_validate_upload_url(UploadHost0, Customer0, Ticket0) ->
    UploadHost = misc:trim(UploadHost0),
    Customer = misc:trim(Customer0),
    Ticket = misc:trim(Ticket0),
    E0 = [{error, {malformed, K}} || {K, V} <- [{customer, Customer},
                                                {ticket, Ticket}],
                                     lists:member($/, V)],
    E1 = [{error, {empty, K}} || {K, V} <- [{customer, Customer},
                                            {uploadHost, UploadHost}],
                                 V =:= ""],
    BasicErrors = E0 ++ E1,
    case BasicErrors =/= [] of
        true ->
            BasicErrors;
        _ ->
            Prefix = case UploadHost of
                         "http://" ++ _ -> "";
                         "https://" ++ _ -> "";
                         _ -> "https://"
                     end,
            Suffix = case lists:reverse(UploadHost) of
                         "/" ++ _ ->
                             "";
                         _ ->
                             "/"
                     end,
            URLNoTicket = Prefix ++ UploadHost ++ Suffix
                ++ mochiweb_util:quote_plus(Customer) ++ "/",
            URL = case Ticket of
                      [] ->
                          URLNoTicket;
                      _ ->
                          URLNoTicket ++ mochiweb_util:quote_plus(Ticket) ++ "/"
                  end,
            [{ok, URL}]
    end.

parse_validate_collect_params(Params, Config) ->
    NodesRV = parse_nodes(proplists:get_value("nodes", Params), Config),

    UploadHost = proplists:get_value("uploadHost", Params),
    Customer = proplists:get_value("customer", Params),
    %% we handle no ticket or empty ticket the same
    Ticket = proplists:get_value("ticket", Params, ""),

    MaybeUpload = case [F || {F, P} <- [{upload, UploadHost},
                                        {customer, Customer}],
                             P =:= undefined] of
                      [_, _] ->
                          case Ticket of
                              "" ->
                                  [{ok, false}];
                              _ ->
                                  [{error, missing_customer},
                                   {error, missing_upload}]
                          end;
                      [] ->
                          parse_validate_upload_url(UploadHost, Customer, Ticket);
                      [upload] ->
                          [{error, missing_upload}];
                      [customer] ->
                          [{error, missing_customer}]
                  end,

    BasicErrors = [E || {error, E} <- [NodesRV | MaybeUpload]],

    case BasicErrors of
        [] ->
            {ok, Nodes} = NodesRV,
            [{ok, Upload}] = MaybeUpload,
            {ok, Nodes, Upload};
        _ ->
            {errors, BasicErrors}
    end.
