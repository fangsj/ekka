%%%===================================================================
%%% Copyright (c) 2013-2018 EMQ Inc. All Rights Reserved.
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
%%%===================================================================

-module(ekka_locker).

-behaviour(gen_server).

-export([start_link/0, start_link/1, start_link/2]).

%% for test cases
-export([stop/0, stop/1]).

-export([aquire/1, aquire/2, aquire/3, release/1, release/2, release/3]).

%% for rpc call
-export([aquire_lock/2, release_lock/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-type(resource() :: term()).

-type(lock_type() :: local | leader | quorum | all).

-export_type([resource/0, lock_type/0]).

-record(lock, {resource :: resource(),
               owner    :: pid(),
               counter  :: integer(),
               created  :: erlang:timestamp()}).

-record(lease, {expiry, timer}).

-record(state, {locks, lease, monitors}).

-define(SERVER, ?MODULE).

%% 15 seconds by default
-define(LEASE_TIME, 15000).

%%%===================================================================
%%% API
%%%===================================================================

-spec(start_link() -> {ok, pid()} | ignore | {error, any()}).
start_link() ->
    start_link(?SERVER).

-spec(start_link(atom()) -> {ok, pid()} | ignore | {error, any()}).
start_link(Name) ->
    start_link(Name, ?LEASE_TIME).

-spec(start_link(atom(), pos_integer()) -> {ok, pid()} | ignore | {error, any()}).
start_link(Name, LeaseTime) ->
    gen_server:start_link({local, Name}, ?MODULE, [Name, LeaseTime], []).

-spec(stop() -> ok).
stop() ->
    stop(?SERVER).

-spec(stop(atom()) -> ok).
stop(Name) ->
    gen_server:call(Name, stop).

-spec(aquire(resource()) -> {boolean(), [node()]}).
aquire(Resource) ->
    aquire(?SERVER, Resource).

-spec(aquire(atom(), resource()) -> {boolean(), [node()]}).
aquire(Name, Resource) when is_atom(Name) ->
    aquire(Name, Resource, local).

-spec(aquire(atom(), resource(), lock_type()) -> {boolean(), [node()]}).
aquire(Name, Resource, local) when is_atom(Name) ->
    {aquire_lock(Name, lock_obj(Resource)), [node()]};
aquire(Name, Resource, leader) when is_atom(Name)->
    Leader = ekka:leader(),
    case rpc:call(Leader, ?MODULE, aquire_lock, [Name, lock_obj(Resource)]) of
        {badrpc, _Reason} ->
            {false, [Leader]};
        Res ->
            {Res, [Leader]}
    end;
aquire(Name, Resource, quorum) when is_atom(Name) ->
    aquire_locks(ekka_ring:find_nodes(Resource), Name, lock_obj(Resource));

aquire(Name, Resource, all) when is_atom(Name) ->
    aquire_locks(ekka_membership:nodelist(up), Name, lock_obj(Resource)).

aquire_locks(Nodes, Name, LockObj) ->
    {ResL, BadNodes} = rpc:multicall(Nodes, ?MODULE, aquire_lock, [Name, LockObj]),
    case (not lists:member(false, ResL)) of
        true  -> {true, Nodes -- BadNodes};
        false -> rpc:multicall(Nodes, ?MODULE, release_lock, [Name, LockObj]),
                 {false, Nodes -- BadNodes}
    end.

aquire_lock(Name, Lock = #lock{resource = Resource, owner = Owner}) ->
    Pos = #lock.counter,
    try ets:update_counter(Name, Resource, [{Pos, 0}, {Pos, 1, 1, 1}]) of
        [0, 1] -> true;
        [1, 1] ->
            case ets:lookup(Name, Resource) of
                [#lock{owner = Owner1}] when Owner1 =:= Owner ->
                    true;
                _Other -> false
            end
    catch
        error:badarg ->
            ets:insert_new(Name, Lock)
    end.

lock_obj(Resource) ->
    #lock{resource = Resource,
          owner    = self(),
          counter  = 1,
          created  = os:timestamp()}.

-spec(release(resource()) -> {boolean(), [node()]}).
release(Resource) ->
    release(?SERVER, Resource).

-spec(release(atom(), resource()) -> {boolean(), [node()]}).
release(Name, Resource) ->
    release(Name, Resource, local).

-spec(release(atom(), resource(), lock_type()) -> {boolean(), [node()]}).
release(Name, Resource, local) ->
    {release_lock(Name, lock_obj(Resource)), [node()]};
release(Name, Resource, leader) ->
    case rpc:call(ekka:leader(), ?MODULE, release, [Name, lock_obj(Resource)]) of
        {badrpc, _Reason} ->
            false;
        Res -> Res
    end;
release(Name, Resource, quorum) ->
    release_locks(ekka_ring:find_nodes(Resource), Name, lock_obj(Resource));
release(Name, Resource, all) ->
    release_locks(ekka_membership:nodelist(up), Name, lock_obj(Resource)).

release_locks(Nodes, Name, LockObj) ->
    {ResL, BadNodes} = rpc:multicall(Nodes, ?MODULE, release_lock, [Name, LockObj]),
    {not lists:member(false, ResL), Nodes -- BadNodes}.

release_lock(Name, #lock{resource = Resource, owner = Owner}) ->
    case ets:lookup(Name, Resource) of
        [Lock = #lock{owner = Owner1}] when Owner1 =:= Owner ->
            ets:delete_object(Name, Lock);
        [_Lock] -> false;
        []      -> false
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name, LeaseTime]) ->
    Tab = ets:new(Name, [public, set, named_table, {keypos, 2},
                         {read_concurrency, true}, {write_concurrency, true}]),
    TRef = timer:send_interval(LeaseTime * 2, check_lease),
    Lease = #lease{expiry = LeaseTime, timer = TRef},
    {ok, #state{locks = Tab, lease = Lease, monitors = #{}}}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    {reply, ignore, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check_lease, State = #state{locks = Tab, lease = Lease, monitors = Monitors}) ->
    Monitors1 = lists:foldl(
                  fun(#lock{resource = Resource, owner = Owner}, MonAcc) ->
                      case maps:find(Owner, MonAcc) of
                          {ok, Resources} ->
                              maps:put(Owner, [Resource|Resources], MonAcc);
                          error ->
                              _MRef = erlang:monitor(process, Owner),
                              maps:put(Owner, [Resource], MonAcc)
                      end
                  end, Monitors, check_lease(Tab, Lease, os:timestamp())),
    {noreply, State#state{monitors = Monitors1}, hibernate};

handle_info({'DOWN', _MRef, process, DownPid, _Reason},
            State = #state{locks = Tab, monitors = Monitors}) ->
    io:format("Lock owner DOWN: ~p~n", [DownPid]),
    case maps:find(DownPid, Monitors) of
        {ok, Resources} ->
            lists:foreach(
              fun(Resource) ->
                  case ets:lookup(Tab, Resource) of
                      [Lock = #lock{owner = Owner}] when Owner =:= DownPid ->
                          ets:delete_object(Tab, Lock);
                      _ -> ok
                  end
              end, Resources),
            {noreply, State#state{monitors = maps:remove(DownPid, Monitors)}};
        error ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State = #state{lease = Lease}) ->
    cancel_lease(Lease).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

check_lease(Tab, #lease{expiry = Expiry}, Now) ->
    check_lease(Tab, ets:first(Tab), Expiry, Now, []).

check_lease(_Tab, '$end_of_table', _Expiry, _Now, Acc) ->
    Acc;
check_lease(Tab, Resource, Expiry, Now, Acc) ->
    check_lease(Tab, ets:next(Tab, Resource), Expiry, Now,
                case ets:lookup(Tab, Resource) of
                    [Lock] ->
                        case is_expired(Lock, Expiry, Now) of
                            true  -> [Lock|Acc];
                            false -> Acc
                        end;
                    [] -> Acc
                end).

is_expired(#lock{created = Created}, Expiry, Now) ->
    (timer:now_diff(Now, Created) div 1000) > Expiry.

cancel_lease(#lease{timer = TRef}) ->
    timer:cancel(TRef).
