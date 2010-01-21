% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

%
% This behavior defines necessary functions making up modules that can
% categorize logging.
%

-module(ns_log_categorizing).

-export([behaviour_info/1]).

behaviour_info(callbacks) ->
    [{ns_log_cat,1},
     {ns_log_code_string,1}];
behaviour_info(_Other) ->
    undefined.
