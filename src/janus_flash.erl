-module(janus_flash).

-export([process/2, forward/2, start/1, stop/1]).

-record(state, {
          socket,
          proxy,
          token,
          last_cmd
         }).

start(Socket) ->
    {ok, Proxy, Token} = client_proxy:start(),
    State = #state{
      socket = Socket, 
      proxy = Proxy, 
      token = Token
     },
    JSON = {struct,
            [{<<"timestamp">>, binary_to_list(term_to_binary(now()))},
             {<<"token">>, Token}
            ]},
    Bin = iolist_to_binary(mochijson2:encode(JSON)),
    Size = byte_size(Bin),
    ok = gen_tcp:send(State#state.socket, [<<Size:16>>, Bin]),
    {ok, State}.

stop(State) ->
    catch client_proxy:detach(State#state.proxy),
    ok.

forward(Bin, State)
  when is_binary(Bin) ->
    Size = byte_size(Bin),
    ok = gen_tcp:send(State#state.socket, [<<Size:16>>, Bin]),
    {ok, State}.

process(heartbeat, State) ->
    ok = gen_tcp:send(State#state.socket, <<4:16, "PING">>),
    {ok, keep_alive, State};

process(ack, State) ->
    ok = gen_tcp:send(State#state.socket, <<3:16, "ACK">>),
    {ok, keep_alive, State};

process(<<>>, State) ->
    {ok, keep_alive, State};

process(<<"<regular-socket/>">>, State) ->
    {ok, keep_alive, State};
    
process(<<"PING">>, State) ->
    {ok, keep_alive, State};
    
process(<<"PONG">>, State) ->
    {ok, keep_alive, State};

process(<<"PUBLISH">>, State) ->
    {ok, keep_alive, State#state{last_cmd=publish}};

process(Bin, State = #state{last_cmd=publish}) ->
  JSON = {struct, [{<<"topic">>, Topic},
                   {<<"event">>, _},
                   {<<"message_id">>, _},
                   {<<"data">>, _}
                  ]} = mochijson2:decode(Bin),
  topman:publish(JSON, Topic),
  {ok, shutdown, State#state{last_cmd=undefined}};

process(Bin, State) ->
    {struct,
     [{<<"action">>, Action}, 
      {<<"data">>, Topic}
     ]} = mochijson2:decode(Bin),
    gen_server:cast(State#state.proxy, {Action, Topic, State#state.socket}),
    {ok, keep_alive, State}.

