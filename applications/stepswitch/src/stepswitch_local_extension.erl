%%%-------------------------------------------------------------------
%%% @copyright (C) 2013-2016, 2600Hz
%%% @doc
%%%
%%% @end
%%% @contributors
%%%-------------------------------------------------------------------
-module(stepswitch_local_extension).

-behaviour(gen_listener).

-export([start_link/2]).
-export([init/1
         ,handle_call/3
         ,handle_cast/2
         ,handle_info/2
         ,handle_event/2
         ,terminate/2
         ,code_change/3
        ]).

-include("stepswitch.hrl").

-define(SERVER, ?MODULE).

-record(state, {number_props = [] :: knm_number_options:extra_options()
                ,resource_req :: kapi_offnet_resource:req()
                ,request_handler :: pid()
                ,control_queue :: api_binary()
                ,response_queue :: api_binary()
                ,queue :: api_binary()
                ,timeout :: reference()
               }).
-type state() :: #state{}.

-define(RESPONDERS, []).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc Starts the server
%%--------------------------------------------------------------------
-spec start_link(knm_number_options:extra_options(), kapi_offnet_resource:req()) -> startlink_ret().
start_link(NumberProps, OffnetReq) ->
    CallId = kapi_offnet_resource:call_id(OffnetReq),
    Bindings = [{'call', [{'callid', CallId}
                          ,{'restrict_to', [<<"CHANNEL_DESTROY">>
                                            ,<<"CHANNEL_EXECUTE_COMPLETE">>
                                            ,<<"CHANNEL_BRIDGE">>
                                           ]}
                         ]}
                ,{'self', []}
               ],
    gen_listener:start_link(?SERVER, [{'bindings', Bindings}
                                      ,{'responders', ?RESPONDERS}
                                      ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], [NumberProps, OffnetReq]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([NumberProps, OffnetReq]) ->
    kz_util:put_callid(OffnetReq),
    case kapi_offnet_resource:control_queue(OffnetReq) of
        'undefined' -> {'stop', 'normal'};
        ControlQ ->
            {'ok', #state{number_props=NumberProps
                          ,resource_req=OffnetReq
                          ,request_handler=self()
                          ,control_queue=ControlQ
                          ,response_queue=kz_api:server_id(OffnetReq)
                          ,timeout=erlang:send_after(120000, self(), 'local_extension_timeout')
                         }}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    lager:debug("unhandled call: ~p", [_Request]),
    {'reply', {'error', 'not_implemented'}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({'kz_amqp_channel', _}, State) ->
    {'noreply', State};
handle_cast({'gen_listener', {'created_queue', Q}}, State) ->
    {'noreply', State#state{queue=Q}};
handle_cast({'gen_listener', {'is_consuming', 'true'}}, #state{control_queue=ControlQ}=State) ->
    Payload = build_local_extension(State),
    'ok' = kapi_dialplan:publish_command(ControlQ, Payload),
    lager:debug("sent local extension command to ~s", [ControlQ]),
    {'noreply', State};
handle_cast({'local_extension_result', _Props}, #state{response_queue='undefined'}=State) ->
    {'stop', 'normal', State};
handle_cast({'local_extension_result', Props}, #state{response_queue=ResponseQ}=State) ->
    kapi_offnet_resource:publish_resp(ResponseQ, Props),
    {'stop', 'normal', State};
handle_cast({'bridged', CallId}, #state{timeout='undefined'}=State) ->
    lager:debug("channel bridged to ~s", [CallId]),
    {'noreply', State};
handle_cast({'bridged', CallId}, #state{timeout=TimerRef}=State) ->
    lager:debug("channel bridged to ~s, canceling timeout", [CallId]),
    _ = erlang:cancel_timer(TimerRef),
    {'noreply', State#state{timeout='undefined'}};
handle_cast(_Msg, State) ->
    lager:debug("unhandled cast: ~p~n", [_Msg]),
    {'noreply', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info('local_extension_timeout', #state{timeout='undefined'}=State) ->
    {'noreply', State};
handle_info('local_extension_timeout', #state{response_queue=ResponseQ
                                              ,resource_req=JObj
                                             }=State) ->
    kapi_offnet_resource:publish_resp(ResponseQ, local_extension_timeout(JObj)),
    {'stop', 'normal', State#state{timeout='undefined'}};
handle_info(_Info, State) ->
    lager:debug("unhandled info: ~p", [_Info]),
    {'noreply', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Allows listener to pass options to handlers
%%
%% @spec handle_event(JObj, State) -> {reply, Options}
%% @end
%%--------------------------------------------------------------------
-spec handle_event(kz_json:object(), state()) -> {'reply', []}.
handle_event(JObj, #state{request_handler=RequestHandler
                          ,resource_req=Request
                         }) ->
    case kapps_util:get_event_type(JObj) of
        {<<"error">>, _} ->
            <<"bridge">> = kz_json:get_value([<<"Request">>, <<"Application-Name">>], JObj),
            lager:debug("channel execution error while waiting for execute extension: ~s"
                        ,[kz_util:to_binary(kz_json:encode(JObj))]),
            gen_listener:cast(RequestHandler, {'local_extension_result', local_extension_error(JObj, Request)});
        {<<"call_event">>, <<"CHANNEL_DESTROY">>} ->
            gen_listener:cast(RequestHandler, {'local_extension_result', local_extension_success(Request)});
        {<<"call_event">>, <<"CHANNEL_EXECUTE_COMPLETE">>} ->
            <<"bridge">> = kz_json:get_value(<<"Application-Name">>, JObj),
            gen_listener:cast(RequestHandler, {'local_extension_result', local_extension_success(Request)});
        {<<"call_event">>, <<"CHANNEL_BRIDGE">>} ->
            CallId = kz_json:get_value(<<"Other-Leg-Call-ID">>, JObj),
            gen_listener:cast(RequestHandler, {'bridged', CallId});
        _ -> 'ok'
    end,
    {'reply', []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    lager:debug("listener terminating: ~p", [_Reason]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec build_local_extension(state()) -> kz_proplist().
build_local_extension(#state{number_props=Props
                             ,resource_req=JObj
                             ,queue=Q
                            }) ->
    {CIDNum, CIDName} = local_extension_caller_id(JObj),
    lager:debug("set outbound caller id to ~s '~s'", [CIDNum, CIDName]),
    Number = knm_number_options:number(Props),
    AccountId = knm_number_options:account_id(Props),
    OriginalAccountId = kz_json:get_value(<<"Account-ID">>, JObj),
    {CEDNum, CEDName} = local_extension_callee_id(JObj, Number),

    Realm = get_account_realm(AccountId),
    CCVsOrig = kz_json:get_value(<<"Custom-Channel-Vars">>, JObj, kz_json:new()),
    CCVs = kz_json:set_values(
             [{<<"Ignore-Display-Updates">>, <<"true">>}
              ,{<<"From-URI">>, bridge_from_uri(Number, JObj)}
              ,{<<"Account-ID">>, OriginalAccountId}
              ,{<<"Reseller-ID">>, kz_services:find_reseller_id(OriginalAccountId)}
             ],
             CCVsOrig),

    CCVUpdates = props:filter_undefined(
                   [{<<?CHANNEL_LOOPBACK_HEADER_PREFIX, "Inception">>, <<Number/binary, "@", Realm/binary>>}
                    ,{<<?CHANNEL_LOOPBACK_HEADER_PREFIX, "Account-ID">>, AccountId}
                    ,{<<?CHANNEL_LOOPBACK_HEADER_PREFIX, "Retain-CID">>, kz_json:get_value(<<"Retain-CID">>, CCVsOrig)}
                    ,{<<"Resource-ID">>, AccountId}
                    ,{<<"Loopback-Request-URI">>, <<Number/binary, "@", Realm/binary>>}
                   ]),

    Endpoint = kz_json:from_list(
                 props:filter_undefined(
                   [{<<"Invite-Format">>, <<"loopback">>}
                    ,{<<"Route">>, Number}
                    ,{<<"To-DID">>, Number}
                    ,{<<"To-Realm">>, Realm}
                    ,{<<"Custom-Channel-Vars">>, kz_json:from_list(CCVUpdates)}
                    ,{<<"Outbound-Caller-ID-Name">>, CIDName}
                    ,{<<"Outbound-Caller-ID-Number">>, CIDNum}
                    ,{<<"Outbound-Callee-ID-Name">>, CEDName}
                    ,{<<"Outbound-Callee-ID-Number">>, CEDNum}
                    ,{<<"Caller-ID-Name">>, CIDName}
                    ,{<<"Caller-ID-Number">>, CIDNum}
                    ,{<<"Ignore-Early-Media">>, 'true'}
                    ,{<<"Enable-T38-Fax">>, 'false'}
                    ,{<<"Enable-T38-Fax-Request">>, 'false'}
                   ])),

    props:filter_undefined(
                [{<<"Application-Name">>, <<"bridge">>}
                 ,{<<"Call-ID">>, kz_json:get_value(<<"Call-ID">>, JObj)}
                 ,{<<"Endpoints">>, [Endpoint]}
                 ,{<<"Dial-Endpoint-Method">>, <<"single">>}
                 ,{<<"Custom-Channel-Vars">>, CCVs}
                 ,{<<"Outbound-Callee-ID-Name">>, CEDName}
                 ,{<<"Outbound-Callee-ID-Number">>, CEDNum}
                 ,{<<"Outbound-Caller-ID-Name">>, CIDName}
                 ,{<<"Outbound-Caller-ID-Number">>, CIDNum}
                 ,{<<"Caller-ID-Name">>, CIDName}
                 ,{<<"Caller-ID-Number">>, CIDNum}
                 ,{<<"Simplify-Loopback">>, <<"false">>}
                 ,{<<"Loopback-Bowout">>, <<"false">>}
                 | kz_api:default_headers(Q, <<"call">>, <<"command">>, ?APP_NAME, ?APP_VERSION)
                ]).

-spec get_account_realm(ne_binary()) -> ne_binary().
get_account_realm(AccountId) ->
    case kz_account:fetch(AccountId) of
        {'ok', JObj} -> kz_account:realm(JObj, AccountId);
        _ -> AccountId
    end.

-spec local_extension_caller_id(kz_json:object()) -> {api_binary(), api_binary()}.
local_extension_caller_id(JObj) ->
    {kz_json:get_first_defined([<<"Outbound-Caller-ID-Number">>
                                ,<<"Emergency-Caller-ID-Number">>
                               ], JObj)
     ,kz_json:get_first_defined([<<"Outbound-Caller-ID-Name">>
                                 ,<<"Emergency-Caller-ID-Name">>
                                ], JObj)
    }.

-spec local_extension_callee_id(kz_json:object(), ne_binary()) -> {api_binary(), api_binary()}.
local_extension_callee_id(JObj, Number) ->
    {kz_json:get_value(<<"Outbound-Callee-ID-Number">>, JObj, Number)
     ,kz_json:get_value(<<"Outbound-Callee-ID-Name">>, JObj, Number)
    }.

-spec local_extension_timeout(kz_json:object()) -> kz_proplist().
local_extension_timeout(Request) ->
    lager:debug("attempt to connect to resources timed out"),
    [{<<"Call-ID">>, kz_json:get_value(<<"Call-ID">>, Request)}
     ,{<<"Msg-ID">>, kz_json:get_value(<<"Msg-ID">>, Request, <<>>)}
     ,{<<"Response-Message">>, <<"NORMAL_TEMPORARY_FAILURE">>}
     ,{<<"Response-Code">>, <<"sip:500">>}
     ,{<<"Error-Message">>, <<"local extension request timed out">>}
     ,{<<"To-DID">>, kz_json:get_value(<<"To-DID">>, Request)}
     | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
    ].

-spec local_extension_error(kz_json:object(), kz_json:object()) -> kz_proplist().
local_extension_error(JObj, Request) ->
    lager:debug("error during outbound request: ~s", [kz_util:to_binary(kz_json:encode(JObj))]),
    [{<<"Call-ID">>, kz_json:get_value(<<"Call-ID">>, Request)}
     ,{<<"Msg-ID">>, kz_json:get_value(<<"Msg-ID">>, Request, <<>>)}
     ,{<<"Response-Message">>, <<"NORMAL_TEMPORARY_FAILURE">>}
     ,{<<"Response-Code">>, <<"sip:500">>}
     ,{<<"Error-Message">>, kz_json:get_value(<<"Error-Message">>, JObj, <<"failed to process request">>)}
     ,{<<"To-DID">>, kz_json:get_value(<<"To-DID">>, Request)}
     | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
    ].

-spec local_extension_success(kz_json:object()) -> kz_proplist().
local_extension_success(Request) ->
    lager:debug("local extension request successfully completed"),
    [{<<"Call-ID">>, kz_json:get_value(<<"Call-ID">>, Request)}
     ,{<<"Msg-ID">>, kz_json:get_value(<<"Msg-ID">>, Request, <<>>)}
     ,{<<"Response-Message">>, <<"SUCCESS">>}
     ,{<<"Response-Code">>, <<"sip:200">>}
     ,{<<"Resource-Response">>, kz_json:new()}
     | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
    ].

-spec bridge_from_uri(api_binary(), kapi_offnet_resource:req()) ->
                             api_binary().
bridge_from_uri(Number, OffnetReq) ->
    Realm = default_realm(OffnetReq),

    case (kapps_config:get_is_true(?SS_CONFIG_CAT, <<"format_from_uri">>, 'false')
          orelse kapi_offnet_resource:format_from_uri(OffnetReq)
         )
        andalso (is_binary(Number)
                 andalso is_binary(Realm)
                )
    of
        'false' -> 'undefined';
        'true' ->
            FromURI = <<"sip:", Number/binary, "@", Realm/binary>>,
            lager:debug("setting bridge from-uri to ~s", [FromURI]),
            FromURI
    end.

-spec default_realm(kapi_offnet_resource:req()) -> api_binary().
default_realm(OffnetReq) ->
    case kapi_offnet_resource:from_uri_realm(OffnetReq) of
        'undefined' -> kapi_offnet_resource:account_realm(OffnetReq);
        Realm -> Realm
    end.
