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
-module(ns_license).

-export([license/1, change_license/2]).

% {"000MEM-BASE00-BETA00", %% A string or the atom undefined if no license.
%  true,                  %% Boolean whether the license is currently valid
%                         %% so this is false if license is invalid or expired.
%  {2010, 9, 15}          %% License is valid until this date, inclusive,
%                         %% in {Y, M, D} format, or the atoms forever or invalid.
% }
%
license(Node) ->
    %% TODO: License placeholder.
    C = ns_config:get(),
    case ns_config:search_prop(C, {node, Node, license}, license) of
        undefined -> {undefined, false, invalid};
        License   -> {License, true, {2010, 11, 15}}
    end.

change_license(Node, "000MEM-BASE00-BETA00" = License) ->
    ns_config:set({node, Node, license}, [{license, License}]),
    ok;

change_license(Node, "2372AA-F32F1G-M3SA01" = License) ->
    ns_config:set({node, Node, license}, [{license, License}]),
    ok;

change_license(_Node, _L) ->
    %% TODO: License change placeholder.  Should validate it and save it if successful.
    {error, todo}.
