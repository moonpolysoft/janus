%%% Copyright (c) 2009 Oortle, Inc

%%% Permission is hereby granted, free of charge, to any person 
%%% obtaining a copy of this software and associated documentation 
%%% files (the "Software"), to deal in the Software without restriction, 
%%% including without limitation the rights to use, copy, modify, merge, 
%%% publish, distribute, sublicense, and/or sell copies of the Software, 
%%% and to permit persons to whom the Software is furnished to do so, 
%%% subject to the following conditions:

%%% The above copyright notice and this permission notice shall be included 
%%% in all copies or substantial portions of the Software.

%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS 
%%% OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL 
%%% THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING 
%%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER 
%%% DEALINGS IN THE SOFTWARE.

-module(flashbot).
-behavior(fast_gen_fsm).

-export([start/1]).

-export([not_connected/2, no_token/2, 
         not_subscribed/2, subscribed/2]).

-export([init/1, handle_event/3, handle_sync_event/4, 
         handle_info/3, terminate/3, code_change/4]).

-record(state, {
          parent,
          host, 
          port,
          token,
          start,
          timer,
          barrier,
          expected,
          socket,
          latency,
          length_left,
          data=[]
         }).

start(Args) ->
    fast_gen_fsm:start_link(?MODULE, Args, []).

init([Parent, Host, Port, Expected, Barrier]) ->
    process_flag(save_calls, 64),
    State = #state{
      parent = Parent,
      host = Host,
      port = Port,
      expected = Expected,
      barrier = Barrier,
      data = []
     },
    catch erlang:monitor(process, Barrier),
    reconnect(),
    {ok, not_connected, State}.

not_connected(connect, State) ->
    case gen_tcp:connect(State#state.host, 
                         State#state.port, 
                         [binary, 
                          {active, true}, 
                          {packet, 0},
                          {reuseaddr, true}
                         ], 3000) of
        {ok, Sock} ->
            State#state.parent ! connected,
            ping(State#state{socket = Sock}, no_token);
        _ ->
            reconnect(),
            {next_state, not_connected, State}
    end.

no_token({struct, [{<<"token">>, Token}]}, State) ->
    State#state.parent ! subscribing,
    JSON = iolist_to_binary(mochijson2:encode({struct, [{action, <<"subscribe">>},
                                       {data, <<"events">>}
                                      ]})),
    Size = byte_size(JSON),
    Data = [<<17:16, "<regular-socket/>">>, <<Size:16>>, JSON],
    send(Data, State#state{token = Token}, not_subscribed).

not_subscribed(ack, State) ->
    %% we are ready
    barrier:bump(State#state.barrier),
    {next_state, subscribed, State#state{start = now()}}.

subscribed(token_timeout, State) ->
    {next_state, subscribed, State};

subscribed(ready, State) ->    
    Ref = fast_gen_fsm:send_event_after(5000, timeout),
    {next_state, subscribed, State#state{start = now(), timer = Ref}};

subscribed(timeout, State) ->    
    State#state.parent ! failure,
    {stop, timeout, State};

subscribed(Expected, State) 
  when Expected == State#state.expected ->
    State#state.parent ! {success, State#state.latency},
    JSON = iolist_to_binary(mochijson2:encode({struct, [{action, <<"unsubscribe">>},
                                       {data, <<"events">>}]})),
    Size = byte_size(JSON),
    Data = [<<17:16, "<regular-socket/>">>, <<Size:16>>, JSON],
    send(Data, State, subscribed),
    {stop, normal, State}.
    
handle_event(Event, Where, State) ->
    {stop, {unknown_event, Event, Where}, State}.

handle_sync_event(Event, From, Where, State) ->
    {stop, {unknown_sync_event, Event, From, Where}, State}.

handle_info({'DOWN', _, process, Pid, normal}, Where, State)
  when Pid == State#state.barrier ->
    ?MODULE:Where(ready, State);

handle_info({tcp, _, <<Length:16/integer, Data/binary>>}, Where, State=#state{length_left=undefined}) ->
  do_framing(Length, Where, Data, State);
  
handle_info({tcp, Sock, Data}, Where, State=#state{length_left=Length, data = BinList}) ->
  do_framing(Length, Where, Data, State);

handle_info(X, _, State) 
  when element(1, X) == tcp_closed;
       element(1, X) == tcp_error ->
    State#state.parent ! disconnected,
    catch fast_gen_fsm:cancel_timer(State#state.timer),
    reconnect(),
    {next_state, not_connected, State#state{timer = none}};

handle_info(Info, Where, State) ->
    {stop, {unknown_info, Info, Where}, State}.

do_framing(Length, Where, Data, State = #state{data=BinList}) ->
  case byte_size(Data) of
    Length -> handle_packet(iolist_to_binary(BinList ++ [Data]), Where, State#state{data=[], length_left=undefined});
    Size when Size > Length ->
      <<Prefix:Length/binary, Tail/binary>> = Data,
      case handle_packet(iolist_to_binary(BinList ++ [Prefix]), Where, State#state{length_left=undefined,data=[]}) of
        {next_state, Where1, State2} -> ?MODULE:handle_info({tcp, State#state.socket, Tail}, Where1, State2);
        Other -> Other
      end;
    Size ->
      {next_state, Where, State#state{length_left=Length-Size, data = BinList ++ [Data]}}
  end.

handle_packet(D = <<"PING">>, Where, State) ->
  % io:format("got ~p~n", [D]),
  send(<<4:16, "PONG">>, State#state.socket, Where);
  
handle_packet(D = <<"ACK">>, Where, State) ->
  % io:format("got ~p~n", [D]),
  ?MODULE:Where(ack, State);
  
handle_packet(Bin, Where, State) ->
  % io:format("got ~p~n", [Bin]),
  Now = now(),
  JSON = mochijson2:decode(Bin),
  %% grab the timestamp
  {struct, [{<<"timestamp">>, TS}|L]} = JSON,
  Delta = timer:now_diff(Now, binary_to_term(list_to_binary(TS))),
  State1 = State#state{latency = Delta},
  ?MODULE:Where({struct, L}, State1).

terminate(_Reason, _Where, State) ->
    catch gen_tcp:close(State#state.socket),
    ok.

code_change(_OldVsn, Where, State, _Extra) ->
    {ok, Where, State}.

send(Bin, State, Where) ->
    case gen_tcp:send(State#state.socket, Bin) of
        ok ->
            {next_state, Where, State};
        _ ->
            reconnect(),
            {next_state, not_connected, State}
    end.

ping(State, Where) ->
    Data = [<<17:16, "<regular-socket/>">>, <<4:16>>, <<"PING">>],
    send(Data, State, Where).
    
reconnect() ->
    flush(),
    fast_gen_fsm:send_event_after(random:uniform(100), connect).

flush() ->
    receive 
        _ ->
            flush()
    after 0 ->
            ok
    end.
