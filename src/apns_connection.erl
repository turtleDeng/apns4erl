%%% @doc This gen_server handles the APNs Connection.
%%%
%%% Copyright 2017 Erlang Solutions Ltd.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%% @end
%%% @copyright Inaka <hello@inaka.net>
%%%
-module(apns_connection).
-author("Felipe Ripoll <felipe@inakanetworks.com>").

-behaviour(gen_server).

%% API
-export([ start_link/2
        , default_connection/2
        , name/1
        , host/1
        , port/1
        , certfile/1
        , keyfile/1
        , type/1
        , http2_connection/1
        , close_connection/1
        , push_notification/4
        , push_notification/5
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-export_type([ name/0
             , host/0
             , port/0
             , path/0
             , connection/0
             , notification/0
             , type/0
             ]).

-type name()         :: atom().
-type host()         :: string() | inet:ip_address().
-type path()         :: string().
-type notification() :: binary().
-type type()         :: cert | token.
-type connection()   :: #{ name       := name()
                         , apple_host := host()
                         , apple_port := inet:port_number()
                         , certfile   => path()
                         , keyfile    => path()
                         , timeout    => integer()
                         , type       := type()
                         }.

-type state()        :: #{ connection       := connection()
                         , http2_connection := pid()
                         , client           := pid()
                         , backoff          := non_neg_integer()
                         , backoff_ceiling  := non_neg_integer()
                         }.

%%%===================================================================
%%% API
%%%===================================================================

%% @doc starts the gen_server
-spec start_link(connection(), pid()) ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link(Connection, Client) ->
  Name = name(Connection),
  gen_server:start_link({local, Name}, ?MODULE, {Connection, Client}, []).

%% @doc Builds a connection() map from the environment variables.
-spec default_connection(type(), name()) -> connection().
default_connection(cert, ConnectionName) ->
  {ok, Host} = application:get_env(apns, apple_host),
  {ok, Port} = application:get_env(apns, apple_port),
  {ok, Certfile} = application:get_env(apns, certfile),
  {ok, Keyfile} = application:get_env(apns, keyfile),
  {ok, Timeout} = application:get_env(apns, timeout),

  #{ name       => ConnectionName
   , apple_host => Host
   , apple_port => Port
   , certfile   => Certfile
   , keyfile    => Keyfile
   , timeout    => Timeout
   , type       => cert
  };
default_connection(token, ConnectionName) ->
  {ok, Host} = application:get_env(apns, apple_host),
  {ok, Port} = application:get_env(apns, apple_port),
  {ok, Timeout} = application:get_env(apns, timeout),

  #{ name       => ConnectionName
   , apple_host => Host
   , apple_port => Port
   , timeout    => Timeout
   , type       => token
  }.

%% @doc Close the connection with APNs gracefully
-spec close_connection(name()) -> ok.
close_connection(ConnectionName) ->
  gen_server:cast(ConnectionName, stop).

%% @doc Returns the http2's connection PID. This function is only used in tests.
-spec http2_connection(name()) -> pid().
http2_connection(ConnectionName) ->
  gen_server:call(ConnectionName, http2_connection).

%% @doc Pushes notification to certificate APNs connection.
-spec push_notification( name()
                       , apns:device_id()
                       , notification()
                       , apns:headers()) -> ok.
push_notification(ConnectionName, DeviceId, Notification, Headers) ->
  gen_server:cast(ConnectionName, {push_notification, DeviceId, Notification, Headers}).
  %wait_response(ConnectionName, Timeout, StreamId).

%% @doc Pushes notification to certificate APNs connection.
-spec push_notification( name()
                       , apns:token()
                       , apns:device_id()
                       , notification()
                       , apns:headers()) -> ok.
push_notification(ConnectionName, Token, DeviceId, Notification, Headers) ->
  gen_server:cast(ConnectionName, {push_notification, Token, DeviceId, Notification, Headers}).
  %wait_response(ConnectionName, Timeout, StreamId).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

-spec init({connection(), pid()}) -> {ok, State :: state()}.
init({Connection, Client}) ->
  process_flag(trap_exit, true),
  ConnectionPid = open_http2_connection(Connection),

  {ok, #{ connection       => Connection
        , http2_connection => ConnectionPid
        , client           => Client
        , backoff          => 1
        , backoff_ceiling  => application:get_env(apns, backoff_ceiling, 10)
        }}.

-spec handle_call( Request :: term(), From :: {pid(), term()}, State) ->
  {reply, ok, State}.
handle_call(http2_connection, _From, #{http2_connection := HTTP2Conn} = State) ->
  {reply, HTTP2Conn, State};
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

-spec handle_cast(Request :: term(), State) ->
  {noreply, State}.
handle_cast({push_notification, DeviceId, Notification, Headers}, State) ->
  #{connection := Connection, http2_connection := HTTP2Conn} = State,
  push(HTTP2Conn, DeviceId, Headers, Notification, Connection),
  {noreply, State};
handle_cast({push_notification, Token, DeviceId, Notification, HeadersMap}, State) ->
  #{connection := Connection, http2_connection := HTTP2Conn} = State,
  Headers = add_authorization_header(HeadersMap, Token),
  push(HTTP2Conn, DeviceId, Headers, Notification, Connection),
  {noreply, State};

handle_cast(stop, State) ->
  {stop, normal, State};
handle_cast(_Request, State) ->
  {noreply, State}.

-spec handle_info(Info :: timeout() | term(), State) -> {noreply, State}.
handle_info( {'EXIT', HTTP2Conn, _}
           , #{ http2_connection := HTTP2Conn
              , client           := Client
              , backoff          := Backoff
              , backoff_ceiling  := Ceiling
              } = State) ->
  ok = h2_client:stop(HTTP2Conn),
  Client ! {reconnecting, self()},
  Sleep = backoff(Backoff, Ceiling) * 1000, % seconds to wait before reconnect
  {ok, _} = timer:send_after(Sleep, reconnect),
  {noreply, State#{backoff => Backoff + 1}};
handle_info(reconnect, State) ->
  #{ connection      := Connection
   , client          := Client
   } = State,
  HTTP2Conn = open_http2_connection(Connection),
  Client ! {connection_up, self()},
  {noreply, State#{http2_connection => HTTP2Conn , backoff => 1}};
handle_info({'END_STREAM', StreamId}, #{http2_connection := HTTP2Conn, client := Client} = State) ->
  {ok, {ResponseHeaders, ResponseBody}} = h2_client:get_response(HTTP2Conn, StreamId),
  {Status, ResponseHeaders2} = normalize_response(ResponseHeaders),
  ResponseBody2 = normalize_response_body(ResponseBody),
  Client ! {apns_response, self(), StreamId, {Status, ResponseHeaders2, ResponseBody2}},
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

-spec terminate( Reason :: (normal | shutdown | {shutdown, term()} | term())
               , State  :: state()
               ) -> ok.
terminate(_Reason, _State) ->
  ok.

-spec code_change(OldVsn :: term() | {down, term()}
                 , State
                 , Extra :: term()
                 ) -> {ok, State}.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Connection getters/setters Functions
%%%===================================================================

-spec name(connection()) -> name().
name(#{name := ConnectionName}) ->
  ConnectionName.

-spec host(connection()) -> host().
host(#{apple_host := Host}) ->
  Host.

-spec port(connection()) -> inet:port_number().
port(#{apple_port := Port}) ->
  Port.

-spec certfile(connection()) -> path().
certfile(#{certfile := Certfile}) ->
  Certfile.

-spec keyfile(connection()) -> path().
keyfile(#{keyfile := Keyfile}) ->
  Keyfile.

-spec type(connection()) -> type().
type(#{type := Type}) ->
  Type.

%%%===================================================================
%%% Internal Functions
%%%===================================================================

-spec open_http2_connection(connection()) -> ConnectionPid :: pid().
open_http2_connection(Connection) ->
  Host = host(Connection),

  TransportOpts = case type(Connection) of
    cert ->
      Certfile = certfile(Connection),
      Keyfile = keyfile(Connection),
      [{certfile, Certfile}, {keyfile, Keyfile}];
    token ->
      []
  end,
  {ok, ConnectionPid} = h2_client:start_link(https, Host, TransportOpts),
  ConnectionPid.

-spec get_headers(binary(), apns:headers(), connection()) -> list().
get_headers(DeviceId, Headers, Connection) ->
  List = [ {<<"apns-id">>, apns_id}
         , {<<"apns-expiration">>, apns_expiration}
         , {<<"apns-priority">>, apns_priority}
         , {<<"apns-topic">>, apns_topic}
         , {<<"apns-collapse_id">>, apns_collapse_id}
         , {<<"authorization">>, apns_auth_token}
         ],
  F = fun({ActualHeader, Key}) ->
    case (catch maps:get(Key, Headers)) of
      {'EXIT', {{badkey, Key}, _}} -> [];
      Value -> [{ActualHeader, Value}]
    end
  end,
  Headers2 = lists:flatmap(F, List),
  lists:append(Headers2, mandatory_headers(DeviceId, Connection)).

-spec mandatory_headers(binary(), connection()) -> list().
mandatory_headers(DeviceId, #{apple_host := Host, apple_port := Port}) ->
  Host2 = list_to_binary(Host),
  Port2 = integer_to_binary(Port),
  [ {<<":method">>, <<"POST">>}
  , {<<":path">>, get_device_path(DeviceId)}
  , {<<":scheme">>, <<"https">>}
  , {<<":authority">>, <<Host2/binary, $:, Port2/binary>>}
  ].

-spec get_device_path(apns:device_id()) -> binary().
get_device_path(DeviceId) ->
  <<"/3/device/", DeviceId/binary>>.

-spec add_authorization_header(apns:headers(), apnd:token()) -> apns:headers().
add_authorization_header(Headers, Token) ->
  Headers#{apns_auth_token => <<"bearer ", Token/binary>>}.

-spec push(pid(), apns:device_id(), apns:headers(), notification(), connection()) ->
  apns:stream_id().
push(HTTP2Conn, DeviceId, HeadersMap, Notification, Connection) ->
  Headers = get_headers(DeviceId, HeadersMap, Connection),
  {ok, StreamID} = h2_client:send_request(HTTP2Conn, Headers, Notification),
  StreamID.

-spec normalize_response(list()) -> {integer(), list()}.
normalize_response(ResponseHeaders) ->
  {<<":status">>, Status} = lists:keyfind(<<":status">>, 1, ResponseHeaders),
  {binary_to_integer(Status), lists:keydelete(<<":status">>, 1, ResponseHeaders)}.

-spec normalize_response_body(list()) -> list() | no_body.
normalize_response_body([]) ->
  no_body;
normalize_response_body([ResponseBody]) ->
  jsx:decode(ResponseBody).

-spec wait_response(name(), integer(), integer()) -> apns:response().
wait_response(ConnectionName, Timeout, StreamID) ->
  Server = whereis(ConnectionName),
  receive
    {apns_response, Server, StreamID, Response} -> Response
  after
    Timeout -> {timeout, StreamID}
  end.

-spec backoff(non_neg_integer(), non_neg_integer()) -> non_neg_integer().
backoff(N, Ceiling) ->
  case (math:pow(2, N) - 1) of
    R when R > Ceiling ->
      Ceiling;
    NextN ->
      NString = float_to_list(NextN, [{decimals, 0}]),
      list_to_integer(NString)
  end.
