%%%-------------------------------------------------------------------
%%% @copyright (C) 2015, 2600Hz
%%% @doc
%%% Init to be done
%%% @end
%%%-------------------------------------------------------------------
-module(registrar_init).

-export([start_link/0
         ,init/0
        ]).

-include("reg.hrl").

-spec start_link() -> startlink_ret().
start_link() ->
    kz_util:spawn(fun init/0),
    'ignore'.

-spec init() -> any().
init() ->
    kz_util:put_callid(?MODULE),
    kapps_maintenance:refresh(?KZ_SIP_DB).
