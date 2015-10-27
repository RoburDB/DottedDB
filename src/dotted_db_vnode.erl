-module(dotted_db_vnode).
-behaviour(riak_core_vnode).
-include_lib("dotted_db.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").

-export([start_vnode/1,
         init/1,
         terminate/2,
         handle_command/3,
         handle_info/2,
         is_empty/1,
         delete/1,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_coverage/4,
         handle_exit/3
        ]).

-export([
            get_vnode_id/2,
            restart/2,
            inform_peers_restart/2,
            inform_peers_restart2/2,
            recover_keys/2,
            read/3,
            repair/3,
            write/6,
            replicate/4,
            sync_start/2,
            sync_missing/4,
            sync_repair/5
        ]).

-ignore_xref([
             start_vnode/1
             ]).

-type dets()        :: reference().

-record(state, {
        % node id used for in logical clocks
        id          :: vnode_id(),
        % the atom representing the vnode id
        atom_id     :: atom(),
        % index on the consistent hashing ring
        index       :: index(),
        % node logical clock
        clock       :: bvv(),
        % key->value store, where the value is a DCC (values + logical clock)
        storage     :: dotted_db_storage:storage(),
        % what peer nodes have from my coordinated writes (not real-time)
        replicated  :: vv(),
        % log for keys that this node coordinated a write (eventually older keys are safely pruned)
        keylog      :: keylog(),
        % the left list of pairs of deleted keys not yet stripped, and their causal context (version vector);
        % the right side is a list of (vnode, map), where the map is between dots and keys not yet completely stripped (and their VV also)
        non_stripped_keys :: {[{key(),vv()}], [{id(), dict:dict()}]},
        % interval in which the vnode tries to strip the non-stripped-keys
        buffer_strip_interval :: non_neg_integer(),
        % temporary list of nodes recovering from failure and a list of keys to send
        recover_keys :: [{id(), [bkey()]}],
        % number of updates (put or deletes) since saving node state to storage
        updates_mem :: integer(),
        % DETS table that stores in disk the vnode state
        dets        :: dets(),
        % a flag to collect or not stats
        stats       :: boolean(),
        % syncs stats
        syncs       :: [{id(), integer(), integer(), os:timestamp(), os:timestamp()}],
        % what mode the vnode is on
        mode        :: normal | recovering,
        % interval time between reports on this vnode
        report_interval :: non_neg_integer()
    }).

-type state() :: #state{}.

-define(MASTER, dotted_db_vnode_master).
-define(UPDATE_LIMITE, 100). % save vnode state every 100 updates
-define(VNODE_STATE_FILE, "dotted_db_vnode_state").
-define(VNODE_STATE_KEY, "dotted_db_vnode_state_key").

%%%===================================================================
%%% API
%%%===================================================================

start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

get_vnode_id(IndexNodes, MyNodeID) ->
    riak_core_vnode_master:command(IndexNodes,
                                   {get_vnode_id, MyNodeID},
                                   {raw, undefined, self()},
                                   ?MASTER).

restart(IndexNodes, ReqID) ->
    riak_core_vnode_master:command(IndexNodes,
                                   {restart, ReqID},
                                   {fsm, undefined, self()},
                                   ?MASTER).

inform_peers_restart(Peers, Args) ->
    riak_core_vnode_master:command(Peers,
                                   {inform_peers_restart, Args},
                                   {fsm, undefined, self()},
                                   ?MASTER).

inform_peers_restart2(Peers, Args) ->
    riak_core_vnode_master:command(Peers,
                                   {inform_peers_restart2, Args},
                                   {fsm, undefined, self()},
                                   ?MASTER).


recover_keys(Peers, Args) ->
    riak_core_vnode_master:command(Peers,
                                   {recover_keys, Args},
                                   {fsm, undefined, self()},
                                   ?MASTER).

read(ReplicaNodes, ReqID, Key) ->
    riak_core_vnode_master:command(ReplicaNodes,
                                   {read, ReqID, Key},
                                   {fsm, undefined, self()},
                                   ?MASTER).

repair(OutdatedNodes, BKey, DCC) ->
    riak_core_vnode_master:command(OutdatedNodes,
                                   {repair, BKey, DCC},
                                   {fsm, undefined, self()},
                                   ?MASTER).

write(Coordinator, ReqID, Op, Key, Value, Context) ->
    riak_core_vnode_master:command(Coordinator,
                                   {write, ReqID, Op, Key, Value, Context},
                                   {fsm, undefined, self()},
                                   ?MASTER).

replicate(ReplicaNodes, ReqID, Key, DCC) ->
    riak_core_vnode_master:command(ReplicaNodes,
                                   {replicate, ReqID, Key, DCC},
                                   {fsm, undefined, self()},
                                   ?MASTER).

sync_start(Node, ReqID) ->
    riak_core_vnode_master:command(Node,
                                   {sync_start, ReqID},
                                   {fsm, undefined, self()},
                                   ?MASTER).

sync_missing(Peer, ReqID, RemoteNodeID, RemoteEntry) ->
    riak_core_vnode_master:command(Peer,
                                   {sync_missing, ReqID, RemoteNodeID, RemoteEntry},
                                   {fsm, undefined, self()},
                                   ?MASTER).

sync_repair(Node, ReqID, RemoteNodeID, RemoteNodeClockBase, MissingObjects) ->
    riak_core_vnode_master:command(Node,
                                   {sync_repair, ReqID, RemoteNodeID, RemoteNodeClockBase, MissingObjects},
                                   {fsm, undefined, self()},
                                   ?MASTER).


%%%===================================================================
%%% Callbacks
%%%===================================================================

init([Index]) ->
    process_flag(priority, high),
    % try to read the vnode state in the DETS file, if it exists
    {Dets, NodeId2, NodeClock, KeyLog, Replicated, NonStrippedKeys} =
        case read_vnode_state(Index) of
            {Ref, not_found} -> % there isn't a past vnode state stored
                lager:debug("No persisted state for vnode index: ~p.",[Index]),
                Clock = bvv:new(),
                KLog  = {0,[]},
                Repli = [],
                {Ref, new_vnode_id(Index), Clock, KLog, Repli, {[],[]}};
            {Ref, error, Error} -> % some unexpected error
                lager:error("Error reading vnode state from storage: ~p", [Error]),
                Clock = bvv:new(),
                KLog  = {0,[]},
                Repli = [],
                {Ref, new_vnode_id(Index), Clock, KLog, Repli, {[],[]}};
            {Ref, {Id, Clock, KLog, Repli, NSK}} -> % we have vnode state in the storage
                lager:info("Recovered state for vnode ID: ~p.",[Id]),
                {Ref, Id, Clock, KLog, Repli, NSK}
        end,
    % open the storage backend for the key-values of this vnode
    {Storage, NodeId3, NodeClock2, KeyLog2, Replicated2, NonStrippedKeys2} =
        case open_storage(Index) of
            {{backend, ets}, S} ->
                % if the storage is in memory, start with an "empty" vnode state
                {S, new_vnode_id(Index), bvv:new(), {0,[]}, [], {[],[]}};
            {_, S} ->
                {S, NodeId2,NodeClock, KeyLog, Replicated, NonStrippedKeys}
        end,
    % create an ETS to store keys written and deleted in this node (for stats)
    AtomID = create_ets_all_keys(NodeId3),
    % schedule a periodic reporting message (wait 2 seconds initially)
    schedule_report(2000),
    % schedule a periodic strip of local keys
    schedule_strip_keys(2000),
    {ok, #state{
        % for now, lets use the index in the consistent hash as the vnode ID
        id                      = NodeId3,
        atom_id                 = AtomID,
        index                   = Index,
        clock                   = NodeClock2,
        replicated              = Replicated2,
        keylog                  = KeyLog2,
        non_stripped_keys       = NonStrippedKeys2,
        buffer_strip_interval   = ?BUFFER_STRIP_INTERVAL,
        recover_keys            = [],
        storage                 = Storage,
        dets                    = Dets,
        updates_mem             = 0,
        stats                   = application:get_env(dotted_db, do_stats, ?DEFAULT_DO_STATS),
        syncs                   = initialize_syncs(Index),
        mode                    = normal,
        report_interval         = ?REPORT_TICK_INTERVAL
        }
    }.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% READING
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_command(Cmd={read, _ReqID, _Key}, _Sender, State) ->
    handle_read(Cmd, State);

handle_command({repair, BKey, NewDCC}, Sender, State) ->
    {reply, {ok, dummy_req_id}, State2} =
        handle_command({replicate, dummy_req_id, BKey, NewDCC}, Sender, State),
    {noreply, State2};


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% WRITING
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_command(Cmd={write, _ReqID, _Operation, _Key, _Value, _Context}, _Sender, State) ->
    % % debug
    % RN = dotted_db_utils:replica_nodes(Key),
    % This = {State#state.index, node()},
    % case lists:member(This, RN) of
    %     true   ->
    %         ok;
    %     false ->
    %         lager:info("WRONG NODE!!!! IxNd: ~p work vnode for key ~p in ~p", [This, Key, RN])
    % end,
    handle_write(Cmd, State);

handle_command(Cmd={replicate, _ReqID, _Key, _NewDCC}, _Sender, State) ->
    % % debug
    %  RN = dotted_db_utils:replica_nodes(Key),
    %  This = {State#state.index, node()},
    %  case lists:member(This, RN) of
    %      true   ->
    %          ok;
    %      false ->
    %          lager:info("WRONG NODE!!! (2)IxNd: ~p work vnode for key ~p in ~p", [This, Key, RN])
    %  end,
    handle_replicate(Cmd, State);


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% SYNCHRONIZING
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_command(Cmd={sync_start, _ReqID}, _Sender, State) ->
    handle_sync_start(Cmd, State);

handle_command(Cmd={sync_missing, _ReqID, _RemoteID, _LocalEntryInRemoteClock}, _Sender, State) ->
    handle_sync_missing(Cmd, State);

handle_command(Cmd={sync_repair, _ReqID, _RemoteNodeID, _RemoteClockBase, _MissingObjects}, _Sender, State) ->
    handle_sync_repair(Cmd, State);


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Restarting Vnode (and recovery of keys)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% On the restarting node
handle_command(Cmd={restart, _ReqID}, _Sender, State) ->
    handle_restart(Cmd, State);

%% On the good nodes
handle_command(Cmd={inform_peers_restart, {_ReqID, _RestartingVnode, _OldVnodeID, _NewVnodeID, _RemoteBase}}, _Sender, State) ->
    handle_inform_peers_restart(Cmd, State);

%% On the restarting node
handle_command(Cmd={recover_keys, {_ReqID, _RemoteVnode, _RemoteVnodeId, _RemoteClock, _Objects, _LastBatch}}, _Sender, State) ->
    handle_recover_keys(Cmd, State);

%% On the good nodes
handle_command(Cmd={inform_peers_restart2, {_ReqID, _NewVnodeID}}, _Sender, State) ->
    handle_inform_peers_restart2(Cmd, State);

%% Sample command: respond to a ping
handle_command(ping, _Sender, State) ->
    {reply, {pong, State#state.id}, State};

handle_command(get_vnode_state, _Sender, State) ->
    {reply, {pong, State}, State};

handle_command({set_strip_interval, NewStripInterval}, _Sender, State) ->
    OldStripInterval = State#state.buffer_strip_interval,
    lager:info("Strip Interval => from: ~p \t to: ~p",[OldStripInterval,NewStripInterval]),
    {noreply, State#state{buffer_strip_interval=NewStripInterval}};

handle_command({set_stats, NewStats}, _Sender, State) ->
    OldStats = State#state.stats,
    lager:info("Vnode stats => from: ~p \t to: ~p",[OldStats, NewStats]),
    {noreply, State#state{stats=NewStats}};

handle_command({get_vnode_id, RemoteID}, _Sender, State) ->
    RemoteCounter = vv:get(RemoteID, State#state.replicated),
    {reply, {get_vnode_id, {State#state.index, node()}, State#state.id, RemoteCounter}, State};

handle_command(Message, _Sender, State) ->
    lager:info("Unhandled Command ~p", [Message]),
    {noreply, State}.


%%%===================================================================
%%% Coverage
%%%===================================================================

handle_coverage(vnode_state, _KeySpaces, {_, RefId, _}, State) ->
    {reply, {RefId, {ok, vs, State}}, State};

handle_coverage(actual_deleted_keys, _KeySpaces, {_, RefId, _}, State) ->
    ADelKeys = get_actual_deleted_keys(State#state.atom_id),
    {reply, {RefId, {ok, adk, ADelKeys}}, State};

handle_coverage(issued_deleted_keys, _KeySpaces, {_, RefId, _}, State) ->
    IDelKeys = get_issued_deleted_keys(State#state.atom_id),
    Res = case length(IDelKeys) > 0 of
        true ->
            Key = hd(IDelKeys),
            case dotted_db_storage:get(State#state.storage, Key) of
                {error, not_found} ->
                    % there is Key was deleted locally (improbable, since there was a 0 in the ETS)
                    {Key, not_found};
                {error, Error} ->
                    % some unexpected error
                    lager:error("Error reading a key from storage: ~p", [Error]),
                    % assume that the key was lost, i.e. it's equal to not_found
                    {Key, storage_error};
                DCC ->
                    % save the new k\v and remove unnecessary causal information
                    {Key, dcc:strip(DCC, State#state.clock), DCC}
            end;
        false ->
            {}
    end,
    ThisVnode = {State#state.index, node()},
    {reply, {RefId, {ok, idk, IDelKeys, Res, ThisVnode}}, State};

handle_coverage(written_keys, _KeySpaces, {_, RefId, _}, State) ->
    WrtKeys = get_written_keys(State#state.atom_id),
    Res = case length(WrtKeys) > 0 of
        true ->
            Key = hd(WrtKeys),
            case dotted_db_storage:get(State#state.storage, Key) of
                {error, not_found} ->
                    % there is Key was deleted locally (improbable, since there was a 0 in the ETS)
                    {Key, not_found};
                {error, Error} ->
                    % some unexpected error
                    lager:error("Error reading a key from storage: ~p", [Error]),
                    % assume that the key was lost, i.e. it's equal to not_found
                    {Key, storage_error};
                DCC ->
                    % save the new k\v and remove unnecessary causal information
                    {Key, dcc:strip(DCC, State#state.clock), DCC}
            end;
        false ->
            {}
    end,
    ThisVnode = {State#state.index, node()},
    {reply, {RefId, {ok, wk, WrtKeys, Res, ThisVnode}}, State};

handle_coverage(final_written_keys, _KeySpaces, {_, RefId, _}, State) ->
    WrtKeys = get_final_written_keys(State#state.atom_id),
    {reply, {RefId, {ok, fwk, WrtKeys}}, State};

handle_coverage(Req, _KeySpaces, _Sender, State) ->
    % lager:warning("unknown coverage received ~p", [Req]),
    lager:info("unknown coverage received ~p", [Req]),
    {noreply, State}.


handle_info({undefined,{get_vnode_id, IndexNode={Index,_}, VnodeID={Index,_}, MyRemoteCounter}}, State) ->
    lager:info("New vnode id for Replicated VV: ~p ", [VnodeID]),
    case lists:member(IndexNode, dotted_db_utils:peers(State#state.index)) of
        true   ->
            F = fun({Idx,_},_) -> Idx =/= Index end,
            Replicated0 = vv:filter(F, State#state.replicated),
            Replicated1 = vv:add(Replicated0, {VnodeID,MyRemoteCounter}),
            {ok, State#state{replicated=Replicated1}};
        false ->
            lager:info("WRONG NODE ID! IxNd: ~p ", [IndexNode]),
            {ok, State}
    end;
%% Report Tick
handle_info(report_tick, State=#state{stats=false}) ->
    schedule_report(State#state.report_interval),
    {ok, State};
handle_info(report_tick, State=#state{stats=true}) ->
    {_, NextState} = report(State),
    schedule_report(State#state.report_interval),
    {ok, NextState};
%% Buffer Strip Tick
handle_info(strip_keys, State=#state{mode=recovering}) ->
    % schedule the strip for keys that still have causal context at the moment
    schedule_strip_keys(State#state.buffer_strip_interval),
    {ok, State};
handle_info(strip_keys, State=#state{mode=normal, non_stripped_keys=NSKeys}) ->
    NSKeys2 = read_strip_write(NSKeys, State),
    % Optionally collect stats
    case State#state.stats of
        true ->
            % {D1,W1} = NSKeys,
            % {D2,W2} = NSKeys2,
            % NumNSKeys = lists:sum([dict:size(Dict) || {_,Dict} <- W1]) + length(D1),
            % NumNSKeys2 = lists:sum([dict:size(Dict) || {_,Dict} <- W2]) + length(D2),
            % CCF = NumNSKeys * ?REPLICATION_FACTOR,
            % CCS = NumNSKeys2 * ?REPLICATION_FACTOR, % we don't really know, but assume the worst
            % EntryExampleSize = byte_size(term_to_binary({State#state.id, 123345})),
            % MetaF = EntryExampleSize * ?REPLICATION_FACTOR * NumNSKeys,
            % MetaS = EntryExampleSize * CCS,
            % dotted_db_stats:update_key_meta(State#state.index, NumNSKeys, MetaF, MetaS, CCF, CCS),
            ok;
        false -> ok
    end,
    % schedule the strip for keys that still have causal context at the moment
    schedule_strip_keys(State#state.buffer_strip_interval),
    {ok, State#state{non_stripped_keys=NSKeys2}};
handle_info(Info, State) ->
    lager:info("unhandled_info: ~p",[Info]),
    {ok, State}.

%%%===================================================================
%%% HANDOFF
%%%===================================================================

handle_handoff_command(?FOLD_REQ{foldfun=FoldFun, acc0=Acc0}, _Sender, State) ->
    % we need to wrap the fold function because it expect 3 elements (K,V,Acc),
    % and our storage layer expect 2 elements ({K,V},Acc).
    WrapperFun = fun({Key,Val}, Acc) -> FoldFun(Key, Val, Acc) end,
    Acc = dotted_db_storage:fold(State#state.storage, WrapperFun, Acc0),
    {reply, Acc, State};

%% Ignore AAE sync requests
handle_handoff_command(Cmd, _Sender, State) when
        element(1, Cmd) == sync_start orelse
        element(1, Cmd) == sync_missing orelse
        element(1, Cmd) == sync_repair ->
    {drop, State};

handle_handoff_command(Cmd, Sender, State) when
        element(1, Cmd) == replicate orelse
        element(1, Cmd) == repair ->
    case handle_command(Cmd, Sender, State) of
        {noreply, State2} ->
            {forward, State2};
        {reply, {ok,_}, State2} ->
            {forward, State2}
    end;

%% For coordinating writes, do it locally and forward the replication
handle_handoff_command(Cmd={write, ReqID, _, Key, _, _}, Sender, State) ->
    lager:info("HAND_WRITE: {~p, ~p} // Key: ~p",[State#state.id, node(), Key]),
    % do the local coordinating write
    {reply, {ok, ReqID, NewDCC}, State2} = handle_command(Cmd, Sender, State),
    % send the ack to the PUT_FSM
    riak_core_vnode:reply(Sender, {ok, ReqID, NewDCC}),
    % create a new request to forward the replication of this new DCC/object
    NewCommand = {replicate, ReqID, Key, NewDCC},
    {forward, NewCommand, State2};

%% Handle all other commands locally (only gets?)
handle_handoff_command(Cmd, Sender, State) ->
    lager:info("Handoff command ~p at ~p", [Cmd, State#state.id]),
    handle_command(Cmd, Sender, State).

handoff_starting(TargetNode, State) ->
    lager:info("HAND_START: {~p, ~p} to ~p",[State#state.index, node(), TargetNode]),
    %% save the vnode state, if not empty
    ok = case State#state.clock =:= bvv:new() of
        true -> ok;
        false ->
            Key = {?DEFAULT_BUCKET, {?VNODE_STATE_KEY, State#state.index}},
            NodeState = {State#state.clock, State#state.keylog, State#state.replicated, State#state.non_stripped_keys},
            dotted_db_storage:put(State#state.storage, Key, NodeState)
    end,
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(Data, State) ->
    NodeKey = {?DEFAULT_BUCKET, {?VNODE_STATE_KEY, State#state.index}},
    % decode the data received
    NewState = 
        case dotted_db_utils:decode_kv(Data) of
            {NodeKey, {NodeClock, KeyLog, Replicated, NSK}} ->
                NodeClock2 = bvv:join(NodeClock, State#state.clock),
                State#state{clock = NodeClock2, keylog = KeyLog, replicated = Replicated, non_stripped_keys = NSK};
            {Key, Obj} ->
                {reply, {ok, _}, State2} = handle_command({replicate, dummy_req_id, Key, Obj}, undefined, State),
                State2
        end,
    {reply, ok, NewState}.

encode_handoff_item(Key, Val) ->
    dotted_db_utils:encode_kv({Key,Val}).

is_empty(State) ->
    case dotted_db_storage:is_empty(State#state.storage) of
        true ->
            {true, State};
        false ->
            lager:info("IS_EMPTY: not empty -> {~p, ~p}",[State#state.index, node()]),
            {false, State}
    end.

delete(State) ->
    {Good, Storage1} = 
        case dotted_db_storage:drop(State#state.storage) of
            {ok, Storage} ->
                {true, Storage};
            {error, Reason, Storage} ->
                lager:info("BAD_DROP: {~p, ~p}  Reason: ~p",[State#state.index, node(), Reason]),
                {false, Storage}
        end,
    case State#state.clock =/= [] andalso Good of
        true  -> 
            lager:info("IxNd:~p // Clock:~p // KL:~p // VV:~p",
                [{State#state.index, node()}, State#state.clock, State#state.keylog, State#state.replicated] ),
            lager:info("GOOD_DROP: {~p, ~p}",[State#state.index, node()]);
        false -> ok
    end,
    true = delete_ets_all_keys(State#state.atom_id),
    {ok, State#state{storage=Storage1}}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    lager:debug("HAND_TERM: {~p, ~p}",[State#state.index, node()]),
    close_all(State),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Private
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% READING
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_read({read, ReqID, Key}, State) ->
    Response =
        case dotted_db_storage:get(State#state.storage, Key) of
            {error, not_found} ->
                % there is no key K in this node
                % create an empty "object" and fill its causality with the node clock
                % this is needed to ensure that deletes "win" over old writes at the coordinator
                {ok, fill_clock(Key, dcc:new(), State#state.clock)};
            {error, Error} ->
                % some unexpected error
                lager:error("Error reading a key from storage (command read): ~p", [Error]),
                % return the error
                {error, Error};
            DCC ->
                % get and fill the causal history of the local object
                {ok, fill_clock(Key, DCC, State#state.clock)}
        end,
    % Optionally collect stats
    case State#state.stats of
        true -> ok;
        false -> ok
    end,
    IndexNode = {State#state.index, node()},
    {reply, {ok, ReqID, IndexNode, Response}, State}.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% WRITING
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


handle_write({write, ReqID, Operation, Key, Value, Context}, State) ->
    % get and fill the causal history of the local key
    DiskDCC = guaranteed_get(Key, State),
    % discard obsolete values w.r.t the causal context
    DiscardDCC = dcc:discard(DiskDCC, Context),
    % generate a new dot for this write/delete and add it to the node clock
    {Dot, NodeClock} = bvv:event(State#state.clock, State#state.id),
    % test if this is a delete; if not, add dot-value to the DCC container
    NewDCC =
        case Operation of
            ?DELETE_OP  -> % DELETE
                % DiscardDCC;
                dcc:add(DiscardDCC, {State#state.id, Dot}, ?DELETE_OP);
            ?WRITE_OP   -> % PUT
                dcc:add(DiscardDCC, {State#state.id, Dot}, Value)
        end,
    % save the new k\v and remove unnecessary causal information
    _= strip_save_batch([{Key, NewDCC}], State#state{clock=NodeClock}),
    % append the key to the tail of the key log
    {Base, Keys} = State#state.keylog,
    KeyLog = {Base, Keys ++ [Key]},
    % Optionally collect stats
    case State#state.stats of
        true ->  ok;
        false -> ok
    end,
    % return the updated node state
    {reply, {ok, ReqID, NewDCC},
        State#state{clock = NodeClock, keylog = KeyLog}}.


handle_replicate({replicate, ReqID, Key, NewDCC}, State) ->
    NodeClock = dcc:add(State#state.clock, NewDCC),
    % get and fill the causal history of the local key
    DiskDCC = guaranteed_get(Key, State),
    % synchronize both objects
    FinalDCC = dcc:sync(NewDCC, DiskDCC),
    % test if the FinalDCC has newer information
    NSK = case FinalDCC == DiskDCC of
        true ->
            lager:debug("Replicated object is ignored (already seen)"),
            State#state.non_stripped_keys;
        false ->
            % save the new key DCC, while stripping the unnecessary causality
            case strip_save_batch([{Key, FinalDCC}], State#state{clock=NodeClock}) of
                [] ->
                    State#state.non_stripped_keys;
                _ ->
                    add_key_to_NSK(Key, NewDCC, State#state.non_stripped_keys)
            end
    end,
    % Optionally collect stats
    case State#state.stats andalso FinalDCC =/= DiskDCC of
        true ->  ok;
        false -> ok
    end,
    % return the updated node state
    {reply, {ok, ReqID}, State#state{clock = NodeClock, non_stripped_keys = NSK}}.




%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% SYNCHRONIZING
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_sync_start({sync_start, ReqID}, State=#state{mode=recovering}) ->
    {reply, {cancel, ReqID, recovering}, State};
handle_sync_start({sync_start, ReqID}, State=#state{mode=normal}) ->
    % choose a peer at random
    NodeB = {IndexB, _} = dotted_db_utils:random_from_list(dotted_db_utils:peers(State#state.index)),
    % get the NodeB entry from this node clock
    EntryB = bvv:get(IndexB, State#state.clock),
    % send a sync message to that node
    {reply, {ok, ReqID, State#state.id, NodeB, EntryB}, State}.


handle_sync_missing({sync_missing, ReqID, _, _}, State=#state{mode=recovering}) ->
    {reply, {cancel, ReqID, recovering}, State};
handle_sync_missing({sync_missing, ReqID, RemoteID={_,_}, LocalEntryInRemoteClock}, State=#state{mode=normal}) ->
    {RemoteIndex,_} = RemoteID,
    % get the all the dots (only the counters) from the local node clock, with id equal to the local node
    LocalDots = bvv:values(bvv:get(State#state.id, State#state.clock)),
    % get the all the dots (only the counters) from the asking node clock, with id equal to the local node
    RemoteDots =  bvv:values(LocalEntryInRemoteClock),
    % calculate what dots are present locally that the asking node does not have
    MisssingDots = LocalDots -- RemoteDots,
    {KBase, KeyList} = State#state.keylog,
    % get the keys corresponding to the missing dots,
    MissingKeys = [lists:nth(MDot-KBase, KeyList) || MDot <- MisssingDots, MDot > KBase],
    % filter the keys that the asking node does not replicate
    RelevantMissingKeys = [Key || Key <- MissingKeys,
                            lists:member(RemoteIndex, dotted_db_utils:replica_nodes_indices(Key))],
    % get each key's respective DCC
    RelevantMissingObjects = [{Key, guaranteed_get_no_fill(Key, State)} || Key <- RelevantMissingKeys],
    % strip any unnecessary causal information to save network bandwidth
    StrippedObjects = [{Key, dcc:strip(DCC, State#state.clock)} || {Key,DCC} <- RelevantMissingObjects],
    % Optionally collect stats
    case State#state.stats andalso MissingKeys > 0 of
        true ->
            case length(StrippedObjects) > 0 of
                true ->
                    Ratio_Relevant_Keys = round(100*length(RelevantMissingKeys)/max(1,length(MissingKeys))),
                    dotted_db_stats:notify({histogram, sync_relevant_ratio}, Ratio_Relevant_Keys),
                    
                    Ctx_Sent_Strip = [dcc:context(DCC) || {_Key, DCC} <- StrippedObjects],
                    Sum_Ctx_Sent_Strip = lists:sum([length(DCC) || DCC <- Ctx_Sent_Strip]),
                    Ratio_Sent_Strip = Sum_Ctx_Sent_Strip/max(1,length(StrippedObjects)),
                    dotted_db_stats:notify({histogram, sync_sent_dcc_strip}, Ratio_Sent_Strip),
        
                    Size_Meta_Sent = byte_size(term_to_binary(Ctx_Sent_Strip)),
                    dotted_db_stats:notify({histogram, sync_metadata_size}, Size_Meta_Sent),
        
                    Payload_Sent_Strip = [{Key, dcc:values(DCC)} || {Key, DCC} <- StrippedObjects],
                    Size_Payload_Sent = byte_size(term_to_binary(Payload_Sent_Strip)),
                    dotted_db_stats:notify({histogram, sync_payload_size}, Size_Payload_Sent),

                    dotted_db_stats:notify({histogram, sync_sent_missing}, length(StrippedObjects)),
                    ok;
                false -> ok
            end;
        false -> ok
    end,
    % send the final objects and the base (contiguous) dots of the node clock to the asking node
    {reply, {   ok,
                ReqID,
                State#state.id,
                bvv:base(State#state.clock),
                bvv:get(RemoteID, State#state.clock), % Remote entry in this node's global clock
                StrippedObjects},
        State}.

handle_sync_repair({sync_repair, ReqID, _, _, _}, State=#state{mode=recovering}) ->
    {reply, {cancel, ReqID, recovering}, State};
handle_sync_repair({sync_repair, ReqID, RemoteNodeID={_,_}, RemoteClockBase, MissingObjects}, State=#state{mode=normal}) ->
    NodeClock = sync_merge_clocks(RemoteNodeID, RemoteClockBase, State),
    % get the local objects corresponding to the received objects and fill the
    % causal history for all of them
    FilledObjects =
        [{ Key, fill_clock(Key, DCC, RemoteClockBase), guaranteed_get(Key, State) }
         || {Key,DCC} <- MissingObjects],
    % synchronize / merge the remote and local objects
    SyncedObjects = [{ Key, dcc:sync(Remote, Local), Local } || {Key, Remote, Local} <- FilledObjects],
    % filter the objects that are not missing after all
    RealMissingObjects = [{ Key, Synced } || {Key, Synced, Local} <- SyncedObjects, Synced =/= Local],
    % save the synced objects and strip their causal history
    NonStrippedObjects = strip_save_batch(RealMissingObjects, State#state{clock=NodeClock}),
    % RealMissingObjects2 = [{Key, DCC, save_kv(Key, DCC, State#state{clock=NodeClock})} || {Key, DCC} <- RealMissingObjects],
    % % filter the keys that were totally stripped
    % NonStrippedObjects = [{Key, DCC} || {Key, DCC, N} <- RealMissingObjects2, N =/= 0],
    % schedule a later strip attempt for non-stripped synced keys
    NSK = add_keys_to_NSK(NonStrippedObjects, State#state.non_stripped_keys),
    % update the replicated clock to reflect what the asking node has about the local node
    {Base,_} = bvv:get(State#state.id, RemoteClockBase),
    Replicated = vv:add(State#state.replicated, {RemoteNodeID, Base}),
    % Garbage Collect keys from the KeyLog and delete keys with no causal context
    State2 = gc_keylog(State#state{clock=NodeClock, non_stripped_keys=NSK, replicated=Replicated}),
    % Optionally collect stats
    case State2#state.stats of
        true ->
            Repaired = length(RealMissingObjects),
            Sent = length(MissingObjects),
            Hit_Ratio = 100*Repaired/max(1, Sent),
            Hit_Ratio =/= 0.0 andalso Sent =/= 0 andalso
                dotted_db_stats:notify({histogram, sync_hit_ratio}, Hit_Ratio),
            ok;
        false ->
            ok
    end,
    {reply, {ok, ReqID}, State2}.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Restarting Vnode (and recovery of keys)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% On the restarting node
handle_restart({restart, ReqID}, State=#state{mode=recovering}) ->
    {reply, {cancel, ReqID, recovering}, State};
handle_restart({restart, ReqID}, State=#state{mode=normal}) ->
    ThisVnode = {State#state.index, node()},
    OldVnodeID = State#state.id,
    {MyBase,0} = bvv:get(OldVnodeID, State#state.clock),
    NewVnodeID = new_vnode_id(State#state.index),
    NewReplicated = vv:reset_with_same_ids(State#state.replicated),
    CurrentPeers = dotted_db_utils:peers(State#state.index),
    true = delete_ets_all_keys(State#state.atom_id),
    NewAtomID = create_ets_all_keys(NewVnodeID),
    {ok, Storage1} = dotted_db_storage:drop(State#state.storage),
    ok = dotted_db_storage:close(Storage1),
    % open the storage backend for the key-values of this vnode
    {_, NewStorage} = open_storage(State#state.index),
    ok = save_vnode_state(State#state.dets, {NewVnodeID, bvv:new(), {0,[]}, NewReplicated, []}),
    {reply, {ok, ReqID, {ReqID, ThisVnode, OldVnodeID, NewVnodeID, MyBase}, CurrentPeers},
        State#state{
            id                  = NewVnodeID,
            atom_id             = NewAtomID,
            clock               = bvv:new(),
            keylog              = {0,[]},
            replicated          = NewReplicated,
            non_stripped_keys   = {[],[]},
            recover_keys        = [],
            storage             = NewStorage,
            syncs               = initialize_syncs(State#state.index),
            updates_mem         = 0,
            mode                = recovering}}.

%% On the good nodes
handle_inform_peers_restart({inform_peers_restart, {ReqID, RestartingVnode, OldVnodeID, NewVnodeID, RemoteBase}}, State) ->
    % jump the base counter of the old id in the node clock, to make sure we "win"
    % against all keys potentially not stripped yet because of that old id
    NodeClock0 = bvv:store_entry(OldVnodeID, {RemoteBase+100000,0}, State#state.clock),
    % add the new node id to the node clock
    NewClock = bvv:add(NodeClock0, {NewVnodeID, 0}),
    % remove the old node id from the replicated
    NewReplicated0 = vv:delete_key(State#state.replicated, OldVnodeID),
    % remove the new node id to the replicated
    NewReplicated = vv:add(NewReplicated0, {NewVnodeID, 0}),
    % add the new node id to the node clock
    AllKeys = get_all_keys(State),
    FunFilter = fun (Key) ->
                    RN = dotted_db_utils:replica_nodes(Key),
                    lists:member(RestartingVnode, RN)
                end,
    RelevantKeys = lists:filter(FunFilter, AllKeys),
    {Now, Later} = lists:split(min(?MAX_KEYS_SENT_RECOVERING,length(RelevantKeys)), RelevantKeys),
    lager:info("Restart transfer => Now: ~p Later: ~p",[length(Now), length(Later)]),
    % get each key's respective DCC
    RelevantMissingObjects = [{Key, guaranteed_get_no_fill(Key, State)} || Key <- Now],
    % strip any unnecessary causal information to save network bandwidth
    StrippedObjects = [{Key, dcc:strip(DCC, NewClock)} || {Key,DCC} <- RelevantMissingObjects],
    % save the rest of the keys for later (if there's any)
    {LastBatch, RecoverKeys} = case Later of
        [] -> {true, State#state.recover_keys};
        _ -> {false, [{NewVnodeID, Later} | State#state.recover_keys]}
    end,
    {reply, { ok, stage1, ReqID, {
                ReqID,
                {State#state.index, node()},
                State#state.id,
                NewClock, %bvv:base(NewClock),
                StrippedObjects,
                LastBatch % is this the last batch?
            }}, State#state{clock=NewClock, replicated=NewReplicated, recover_keys=RecoverKeys}}.

%% On the restarting node
handle_recover_keys({recover_keys, {ReqID, RemoteVnode, _RemoteVnodeId={_,_}, RemoteClock, Objects, _LastBatch=false}}, State) ->
    % save the objects and return the ones that were not totally filtered
    NonStrippedObjects = fill_strip_save_kvs(Objects, RemoteClock, State),
    % schedule a later strip attempt for non-stripped synced keys
    NSK = add_keys_to_NSK(NonStrippedObjects, State#state.non_stripped_keys),
    {reply, {ok, stage2, ReqID, RemoteVnode}, State#state{non_stripped_keys=NSK}};
%% On the restarting node
handle_recover_keys({recover_keys, {ReqID, RemoteVnode, RemoteNodeID={_,_}, RemoteClock, Objects, _LastBatch=true}}, State) ->
    % merge the remote clock with our own clock
    NodeClock0 = bvv:merge(State#state.clock, RemoteClock),
    % filter ids from non-peer nodes
    PeerIndices = [State#state.index]++[Idx || {Idx,_} <- dotted_db_utils:peers(State#state.index)],
    NodeClock = orddict:filter(fun({Index,_}, _) -> lists:member(Index, PeerIndices) end, NodeClock0),
    % update the replicated clock to reflect what the asking node has about the local node
    {Base,_} = bvv:get(State#state.id, RemoteClock),
    Replicated = vv:add(State#state.replicated, {RemoteNodeID, Base}),
    % save the objects and return the ones that were not totally filtered
    NonStrippedObjects = fill_strip_save_kvs(Objects, RemoteClock, State#state{clock=NodeClock}),
    % schedule a later strip attempt for non-stripped synced keys
    NSK = add_keys_to_NSK(NonStrippedObjects, State#state.non_stripped_keys),
    % Garbage Collect keys from the KeyLog and delete keys with no causal context
    State2 = gc_keylog(State#state{clock=NodeClock, non_stripped_keys=NSK, replicated=Replicated}),
    {reply, {ok, stage4, ReqID, RemoteVnode}, State2#state{mode=normal}}.

%% On the good nodes
handle_inform_peers_restart2({inform_peers_restart2, {ReqID, NewVnodeID}}, State) ->
    {LastBatch1, Objects, RecoverKeys1} =
        case proplists:get_value(NewVnodeID, State#state.recover_keys) of
            undefined ->
                {true, [], State#state.recover_keys};
            RelevantKeys ->
                RK = proplists:delete(NewVnodeID, State#state.recover_keys),
                {Now, Later} = lists:split(min(?MAX_KEYS_SENT_RECOVERING,length(RelevantKeys)), RelevantKeys),
                % get each key's respective DCC
                RelevantMissingObjects = [{Key, guaranteed_get_no_fill(Key, State)} || Key <- Now],
                % strip any unnecessary causal information to save network bandwidth
                StrippedObjects = [{Key, dcc:strip(DCC, State#state.clock)} || {Key,DCC} <- RelevantMissingObjects],
                % save the rest of the keys for later (if there's any)
                {LastBatch, RecoverKeys} = case Later of
                    [] -> {true, RK};
                    _ -> {false, [{NewVnodeID, Later} | RK]}
                end,
                {LastBatch, StrippedObjects, RecoverKeys}
        end,
    {reply, { ok, stage3, ReqID, {
                ReqID,
                {State#state.index, node()},
                State#state.id,
                State#state.clock, %bvv:base(State#state.clock),
                Objects,
                LastBatch1 % is this the last batch?
            }}, State#state{recover_keys=RecoverKeys1}}.





%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Aux functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

fill_clock(Key={_,_}, LocalClock, GlobalClock) ->
    % dcc:fill(LocalClock, GlobalClock, dotted_db_utils:replica_nodes_indices(Key)).
    {D,VV} = LocalClock,
    RNIndices = dotted_db_utils:replica_nodes_indices(Key),
    case ?REPLICATION_FACTOR == length(RNIndices) of
        true ->
            % only consider ids that belong to both the list of ids received and the GlobalClock
            Ids2 = [{Index,RandomID} || {Index,RandomID} <- bvv:ids(GlobalClock), 
                                            lists:member(Index, RNIndices)],
            FunFold = 
                fun(Id, Acc) -> 
                    {Base,_D} = bvv:get(Id,GlobalClock),
                    vv:add(Acc,{Id,Base})
                end,
            {D, lists:foldl(FunFold, VV, Ids2)};
        false ->
            lager:error("fill clock: RF:~p RNind:~p for key:~p indices:~p",
                [?REPLICATION_FACTOR, length(RNIndices), Key, RNIndices]),
            % dcc:fill(LocalClock, GlobalClock)
            ?REPLICATION_FACTOR = length(RNIndices)
    end.

% @doc Returns the value (DCC) associated with the Key.
% By default, we want to return a filled causality, unless we get a storage error.
% If the key does not exists or for some reason, the storage returns an
% error, return an empty DCC (also filled).
guaranteed_get(Key, State) ->
    case dotted_db_storage:get(State#state.storage, Key) of
        {error, not_found} ->
            % there is no key K in this node
            fill_clock(Key, dcc:new(), State#state.clock);
        {error, Error} ->
            % some unexpected error
            lager:error("Error reading a key from storage (guaranteed GET): ~p", [Error]),
            % assume that the key was lost, i.e. it's equal to not_found
            dcc:new();
        DCC ->
            % get and fill the causal history of the local object
            fill_clock(Key, DCC, State#state.clock)
    end.


guaranteed_get_no_fill(Key, State) ->
    case dotted_db_storage:get(State#state.storage, Key) of
        {error, not_found} ->
            % there is no key K in this node
            dcc:new();
        {error, Error} ->
            % some unexpected error
            lager:error("Error reading a key from storage (guaranteed GET): ~p", [Error]),
            % assume that the key was lost, i.e. it's equal to not_found
            dcc:new();
        DCC ->
            % get and fill the causal history of the local object
            DCC
    end.

% @doc Saves the relevant vnode state to the storage.
save_vnode_state(Dets, State={Id={Index,_},_,_,_,_}) ->
    Key = {?VNODE_STATE_KEY, Index},
    ok = dets:insert(Dets, {Key, State}),
    ok = dets:sync(Dets),
    lager:debug("Saved state for vnode ~p.",[Id]),
    ok.

% @doc Reads the relevant vnode state from the storage.
read_vnode_state(Index) ->
    Folder = "data/vnode_state/",
    ok = filelib:ensure_dir(Folder),
    FileName = filename:join(Folder, integer_to_list(Index)),
    Ref = list_to_atom(integer_to_list(Index)),
    {ok, Dets} = dets:open_file(Ref,[{type, set},
                                    {file, FileName},
                                    {auto_save, infinity},
                                    {min_no_slots, 1}]),
    Key = {?VNODE_STATE_KEY, Index},
    case dets:lookup(Dets, Key) of
        [] -> % there isn't a past vnode state stored
            {Dets, not_found};
        {error, Error} -> % some unexpected error
            {Dets, error, Error};
        [{Key, State={{Index,_},_,_,_,_}}] ->
            {Dets, State}
    end.

% @doc Initializes the "replicated" version vector to 0 for peers of this vnode.
initialize_replicated(NodeId={Index,_}) ->
    lager:info("Starting init repli @ IndexNode: ~p",[{Index,node()}]),
    % get the Index and Node of this node's peers, i.e., all nodes that replicates any subset of local keys.
    IndexNodes = [ IndexNode || IndexNode <- dotted_db_utils:peers(Index)],
    % for replication factor N = 3, the numbers of peers should be 4 (2 vnodes before and 2 after).
    (?REPLICATION_FACTOR-1)*2 = length(IndexNodes),
    % ask each vnode for their current vnode ID
    get_vnode_id(IndexNodes, NodeId),
    ok.

% @doc Initializes the "sync" stats for peers of this vnode.
initialize_syncs(_Index) ->
    [{dummy_node_id,0,0,0,0}].
%     % get this node's peers, i.e., all nodes that replicates any subset of local keys.
%     PeerIDs = [ ID || {ID, _Node} <- dotted_db_utils:peers(Index)],
%     % for replication factor N = 3, the numbers of peers should be 4 (2 vnodes before and 2 after).
%     (?REPLICATION_FACTOR-1)*2 = length(PeerIDs),
%     Now = os:timestamp(),
%     Syncs = lists:foldl(fun (ID, List) -> [{ID,0,0,Now,Now} | List] end , [], PeerIDs),
%     (?REPLICATION_FACTOR-1)*2 = length(Syncs),
%     Syncs.


% @doc Returns the Storage for this vnode.
open_storage(Index) ->
    % get the preferred backend in the configuration file, defaulting to ETS if
    % there is no preference.
    {Backend, Options} = case application:get_env(dotted_db, storage_backend, ets) of
        leveldb   -> {{backend, leveldb}, []};
        ets       -> {{backend, ets}, []};
        bitcask   -> {{backend, bitcask}, [{db_opts,[
                read_write,
                {sync_strategy, application:get_env(dotted_db, bitcask_io_sync, none)},
                {io_mode, application:get_env(dotted_db, bitcask_io_mode, erlang)},
                {merge_window, application:get_env(dotted_db, bitcask_merge_window, never)}]}]}
    end,
    lager:info("Using ~p for vnode ~p.",[Backend,Index]),
    % give the name to the backend for this vnode using its position in the ring.
    DBName = filename:join("data/objects/", integer_to_list(Index)),
    {ok, Storage} = dotted_db_storage:open(DBName, Backend, Options),
    {Backend, Storage}.

% @doc Close the key-value backend, save the vnode state and close the DETS file.
close_all(undefined) -> ok;
close_all(_State=#state{id          = Id,
                        atom_id     = AtomID,
                        storage     = Storage,
                        clock       = NodeClock,
                        replicated  = Replicated,
                        keylog      = KeyLog,
                        non_stripped_keys = NSK,
                        dets        = Dets } ) ->
    case dotted_db_storage:close(Storage) of
        ok -> ok;
        {error, Reason} ->
            lager:warning("Error on closing storage: ~p",[Reason])
    end,
    ok = save_vnode_state(Dets, {Id, NodeClock, KeyLog, Replicated, NSK}),
    true = delete_ets_all_keys(AtomID),
    ok = dets:close(Dets).

get_issued_deleted_keys(Id) ->
    ets:select(Id, [{{'$1', '$2'}, [{'==', '$2', 0}], ['$1'] }]).

get_actual_deleted_keys(Id) ->
    ets:select(Id, [{{'$1', '$2'}, [{'==', '$2', 1}], ['$1'] }]).

get_written_keys(Id) ->
    ets:select(Id, [{{'$1', '$2'}, [{'==', '$2', 2}], ['$1'] }]).

get_final_written_keys(Id) ->
    ets:select(Id, [{{'$1', '$2'}, [{'==', '$2', 3}], ['$1'] }]).

get_ets_id(Id) ->
    list_to_atom(lists:flatten(io_lib:format("~p", [Id]))).


gc_keylog(State) ->
    {KBase, KeyList} = State#state.keylog,
    case is_replicated_vv_up_to_date(State) of
        true ->
            case KeyList =/= [] of
                true ->
                    % get the oldest dot generated at this node that is also known by all peers of this node (relevant nodes)
                    MinimumDot = vv:min(State#state.replicated),
                    lager:debug("Base:~p MinD: ~p ~nRepli: ~p ~nKL: ~p",[KBase, MinimumDot, State#state.replicated, KeyList]),
                    % remove the keys from the keylog that have a dot (corresponding to their position) smaller than the
                    % minimum dot, i.e., this update is known by all nodes that replicate it and therefore can be removed
                    % from the keylog; for simplicity, remove only keys that start at the head, to actually shrink the log
                    % and increment the base counter.
                    {RemovedKeys, KeyLog} =
                        case MinimumDot > KBase of
                            false -> % we don't need to remove any keys from the log
                                {[], {KBase, KeyList}};
                            true  -> % we can remove keys and shrink the keylog
                                {RemKeys, CurrentKeys} = lists:split(MinimumDot - KBase, KeyList),
                                {RemKeys, {MinimumDot, CurrentKeys}}
                        end,
                    % add the non stripped keys to the node state for later strip attempt
                    NSK = add_keys_from_keylog_to_NSK(RemovedKeys, State#state.id, KBase, State#state.non_stripped_keys),
                    % Optionally collect stats
                    case State#state.stats of
                        true -> ok;
                        false -> ok
                    end,
                    State#state{keylog=KeyLog, non_stripped_keys=NSK};
                false ->
                    State
            end;
        false ->
            State#state.keylog =/= {0,[]} andalso initialize_replicated(State#state.id),
            State
    end.


-spec schedule_strip_keys(non_neg_integer()) -> ok.
schedule_strip_keys(Interval) ->
    erlang:send_after(Interval, self(), strip_keys),
    ok.

-spec schedule_report(non_neg_integer()) -> ok.
schedule_report(Interval) ->
    %% Perform tick every X seconds
    erlang:send_after(Interval, self(), report_tick),
    ok.

-spec report(state()) -> {any(), state()}.
report(State=#state{    id                  = Id,
                        clock               = NodeClock,
                        replicated          = Replicated,
                        keylog              = KeyLog,
                        non_stripped_keys   = NSK,
                        dets                = Dets,
                        updates_mem         = UpMem } ) ->
    report_stats(State),
    % increment the updates since saving
    UpdatesMemory =  case UpMem =< ?UPDATE_LIMITE*50 of
        true -> % it's still early to save to storage
            UpMem + 1;
        false ->
            % it's time to persist vnode state
            save_vnode_state(Dets, {Id, NodeClock, KeyLog, Replicated, NSK}),
            % restart the counter
            0
    end,
    {ok, State#state{updates_mem=UpdatesMemory}}.


report_stats(State=#state{stats=true}) ->
    {_B1,K1} = State#state.keylog,
    dotted_db_stats:notify({histogram, kl_len}, length(K1)),
    dotted_db_stats:notify({histogram, kl_size}, size(term_to_binary(State#state.keylog))),

    MissingDots = [ miss_dots(Entry) || {_,Entry} <- State#state.clock ],
    dotted_db_stats:notify({histogram, bvv_missing_dots}, average(MissingDots)),
    dotted_db_stats:notify({histogram, bvv_size}, size(term_to_binary(State#state.clock))),

    {Del,Wrt} = State#state.non_stripped_keys,
    NumNSKeys = lists:sum([dict:size(Map) || {_, Map} <- Wrt]) + length(Del),
    dotted_db_stats:notify({histogram, nsk_number}, NumNSKeys),
    dotted_db_stats:notify({histogram, nsk_size}, size(term_to_binary(State#state.non_stripped_keys))),

    ADelKeys = length(get_actual_deleted_keys(State#state.atom_id)),
    IDelKeys = length(get_issued_deleted_keys(State#state.atom_id)),
    dotted_db_stats:notify({histogram, deletes_incomplete}, IDelKeys),
    dotted_db_stats:notify({histogram, deletes_completed}, ADelKeys),

    IWKeys = length(get_written_keys(State#state.atom_id)),
    FWKeys = length(get_final_written_keys(State#state.atom_id)),
    dotted_db_stats:notify({histogram, write_incomplete}, IWKeys),
    dotted_db_stats:notify({histogram, write_completed}, FWKeys),
    ok.

miss_dots({N,B}) ->
    case values_aux(N,B,[]) of
        [] -> 0;
        L  -> lists:max(L) - N - length(L)
    end.
values_aux(_,0,L) -> L;
values_aux(N,B,L) ->
    M = N + 1,
    case B rem 2 of
        0 -> values_aux(M, B bsr 1, L);
        1 -> values_aux(M, B bsr 1, [ M | L ])
    end.

average(X) ->
    average(X, 0, 0).
average([H|T], Length, Sum) ->
    average(T, Length + 1, Sum + H);
average([], Length, Sum) ->
    Sum / max(1,Length).



strip_save_batch(O,S) -> strip_save_batch(O,S,true).
strip_save_batch(Objects, State, ETS) ->
    strip_save_batch(Objects, State, {[],[]}, ETS).

strip_save_batch([], State, {NSK, StrippedObjects}, _ETS) ->
    ok = dotted_db_storage:write_batch(State#state.storage, StrippedObjects),
    NSK;
strip_save_batch([{Key={_,_}, DCC} | Objects], State, {NSK, StrippedObjects}, ETS) ->
    % removed unnecessary causality from the DCC, based on the current node clock
    StrippedDCC = {Values, Context} = dcc:strip(DCC, State#state.clock),
    Values2 = [{D,V} || {D,V} <- Values, V =/= ?DELETE_OP],
    % the resulting object/DCC is one of the following options:
    %   * it has no value and no causal history -> can be deleted
    %   * it has no value but has causal history -> it's a delete, but still must be persisted
    %   * has values, with causal context -> it's a normal write and we should persist
    %   * has values, but no causal context -> it's the final form for this write
    Acc = case {Values2, Context} of
        {[],[]} ->
            ETS andalso ets:insert(State#state.atom_id, {Key, 1}),
            {NSK,                       [{delete, Key}|StrippedObjects]};
        {[],_CC} ->
            ETS andalso ets:insert(State#state.atom_id, {Key, 0}),
            {[{Key, StrippedDCC}|NSK],  [{put, Key, StrippedDCC}|StrippedObjects]};
        {_ ,[]} ->
            ETS andalso ets:insert(State#state.atom_id, {Key, 3}),
            {NSK,                       [{put, Key, StrippedDCC}|StrippedObjects]};
        {_ ,_CC} ->
            ETS andalso ets:insert(State#state.atom_id, {Key, 2}),
            {[{Key, StrippedDCC}|NSK],  [{put, Key, StrippedDCC}|StrippedObjects]}
    end,
    strip_save_batch(Objects, State, Acc, ETS).






%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%%      Try to remove elements from Non-Stripped Keys
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Used periodically to see which non-stripped keys can be stripped.
-spec read_strip_write({[{key(),vv()}], [{dot(), dict:dict()}]}, state()) -> {[{key(),vv()}], [{dot(), dict:dict()}]}.
read_strip_write({Deletes, Writes}, State) ->
    {Stripped, NotStripped} = split_deletes(Deletes, State, {[],[]}),
    Deletes2 = strip_maybe_save_delete_batch(Stripped, State) ++ NotStripped,
    Writes2 = compute_writes_NSK(Writes, State, []),
    {Deletes2, Writes2}.

split_deletes([], _State, Acc) -> Acc;
split_deletes([{Key, Ctx} | Deletes], State, {Stripped, NotStripped}) ->
    case strip_context(Ctx,State#state.clock) of
        [] -> 
            case read_one_key(Key, State) of
                0   ->
                    ets:insert(State#state.atom_id, {Key, 1}),
                    split_deletes(Deletes, State, {Stripped, NotStripped});
                DCC ->
                    split_deletes(Deletes, State, {[{Key, DCC}|Stripped], NotStripped})
            end;
        VV ->
            split_deletes(Deletes, State, {Stripped, [{Key, VV}|NotStripped]})
    end.

-spec strip_context(vv(), bvv()) -> vv().
strip_context(Context, NodeClock) ->
    FunFilter = 
        fun (Id, Counter) -> 
            {Base,_Dots} = bvv:get(Id, NodeClock),
            Counter > Base
        end,
    vv:filter(FunFilter, Context).


strip_maybe_save_delete_batch(O,S) -> strip_maybe_save_delete_batch(O,S,true).
strip_maybe_save_delete_batch(Objects, State, ETS) ->
    strip_maybe_save_delete_batch(Objects, State, {[],[]}, ETS).

strip_maybe_save_delete_batch([], State, {NSK, StrippedObjects}, _ETS) ->
    ok = dotted_db_storage:write_batch(State#state.storage, StrippedObjects),
    NSK;
strip_maybe_save_delete_batch([{Key={_,_}, DCC} | Objects], State, {NSK, StrippedObjects}, ETS) ->
    % removed unnecessary causality from the DCC, based on the current node clock
    StrippedDCC = {Values, Context} = dcc:strip(DCC, State#state.clock),
    Values2 = [{D,V} || {D,V} <- Values, V =/= ?DELETE_OP],
    % the resulting object/DCC is one of the following options:
    %   * it has no value and no causal history -> can be deleted
    %   * it has no value but has causal history -> it's a delete, but still must be persisted
    %   * has values, with causal context -> it's a normal write and we should persist
    %   * has values, but no causal context -> it's the final form for this write
    Acc = case {Values2, Context} of
        {[],[]} ->
            ETS andalso ets:insert(State#state.atom_id, {Key, 1}),
            {NSK,                   [{delete, Key}|StrippedObjects]};
        {_ ,[]} ->
            ETS andalso ets:insert(State#state.atom_id, {Key, 3}),
            {NSK,                   [{put, Key, StrippedDCC}|StrippedObjects]};
        {[],_CC} ->
            {[{Key, Context}|NSK],  StrippedObjects};
        {_ ,_CC} ->
            {[{Key, Context}|NSK],  StrippedObjects}
    end,
    strip_maybe_save_delete_batch(Objects, State, Acc, ETS).


compute_writes_NSK([], _State, Acc) -> Acc;
compute_writes_NSK([{NodeID, Map} |Tail], State, Acc) ->
    {Stripped, NotStripped} = split_writes(dict:to_list(Map), State, {[],[]}),
    Writes = strip_maybe_save_writes_batch(Stripped, State) ++ NotStripped,
    Acc2 = case Writes of
        [] -> Acc;
        _  -> [{NodeID, dict:from_list(Writes)} | Acc]
    end,
    compute_writes_NSK(Tail, State, Acc2).

split_writes([], _State, Acc) -> Acc;
split_writes([{Dot, {Key, undefined}} | Deletes], State, {Stripped, NotStripped}) ->
    case read_one_key(Key, State) of
        0   ->
            ets:insert(State#state.atom_id, {Key, 3}),
            split_writes(Deletes, State, {Stripped, NotStripped});
        DCC ->
            split_writes(Deletes, State, {[{Dot, {Key, DCC}}|Stripped], NotStripped})
    end;
split_writes([{Dot, {Key, Ctx}} | Deletes], State, {Stripped, NotStripped}) ->
    case strip_context(Ctx, State#state.clock) of
        [] -> 
            case read_one_key(Key, State) of
                0   ->
                    ets:insert(State#state.atom_id, {Key, 3}),
                    split_writes(Deletes, State, {Stripped, NotStripped});
                DCC ->
                    split_writes(Deletes, State, {[{Dot, {Key, DCC}}|Stripped], NotStripped})
            end;
        VV ->
            split_writes(Deletes, State, {Stripped, [{Dot, {Key, VV}}|NotStripped]})
    end.

strip_maybe_save_writes_batch(O,S) -> strip_maybe_save_writes_batch(O,S,true).
strip_maybe_save_writes_batch(Objects, State, ETS) ->
    strip_maybe_save_writes_batch(Objects, State, {[],[]}, ETS).

strip_maybe_save_writes_batch([], State, {NSK, StrippedObjects}, _ETS) ->
    ok = dotted_db_storage:write_batch(State#state.storage, StrippedObjects),
    NSK;
strip_maybe_save_writes_batch([{Dot, {Key={_,_}, DCC}} | Objects], State, {NSK, StrippedObjects}, ETS) ->
    % removed unnecessary causality from the DCC, based on the current node clock
    StrippedDCC = {Values, Context} = dcc:strip(DCC, State#state.clock),
    Values2 = [{D,V} || {D,V} <- Values, V =/= ?DELETE_OP],
    % the resulting object/DCC is one of the following options:
    %   * it has no value and no causal history -> can be deleted
    %   * it has no value but has causal history -> it's a delete, but still must be persisted
    %   * has values, with causal context -> it's a normal write and we should persist
    %   * has values, but no causal context -> it's the final form for this write
    Acc = case {Values2, Context} of
        {[],[]} ->
            ETS andalso ets:insert(State#state.atom_id, {Key, 1}),
            {NSK,                           [{delete, Key}|StrippedObjects]};
        {_ ,[]} ->
            ETS andalso ets:insert(State#state.atom_id, {Key, 3}),
            {NSK,                           [{put, Key, StrippedDCC}|StrippedObjects]};
        {[],_CC} ->
            {[{Dot, {Key, Context}}|NSK],   StrippedObjects};
        {_ ,_CC} ->
            {[{Dot, {Key, Context}}|NSK],   StrippedObjects}
    end,
    strip_maybe_save_writes_batch(Objects, State, Acc, ETS).


read_one_key(Key={_,_}, State) ->
    case dotted_db_storage:get(State#state.storage, Key) of
        {error, not_found} ->
            0;
        {error, Error} ->
            % some unexpected error
            lager:error("Error reading a key from storage: ~p", [Error]),
            % assume that the key was lost, i.e. it's equal to not_found
            0;
        DCC ->
            DCC
    end.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%%      Add elements to Non-Stripped Keys
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

add_keys_to_NSK([], NSK) -> NSK;
add_keys_to_NSK([{Key, DCC}|Tail], NSK) ->
    NSK2 = add_key_to_NSK(Key, DCC, NSK),
    add_keys_to_NSK(Tail, NSK2).

% @doc Add a replicated key and DCC to the list of non-stripped-keys
add_key_to_NSK(_, {[],[]}, NSK) -> NSK;
add_key_to_NSK(Key, {[],Ctx}, {Del,Wrt}) ->
    {[{Key, Ctx}|Del], Wrt};
add_key_to_NSK(Key, {DotValues,Ctx}, NSK) ->
    KeyDots = [{Key, Dot, Ctx} || {Dot,_} <- DotValues],
    add_writes_to_NSK(KeyDots, NSK).

add_writes_to_NSK([], NSK) -> NSK;
add_writes_to_NSK([Head={_,_,_} | Tail], {Del,Wrt}) ->
    Wrt2 = add_one_write_to_NSK(Head, Wrt),
    add_writes_to_NSK(Tail, {Del,Wrt2}).


add_keys_from_keylog_to_NSK([], _, _, NSK) -> NSK;
add_keys_from_keylog_to_NSK([Key={_,_}|Tail], NodeID={_,_}, Base, {Del,Wrt}) ->
    Wrt2 = add_one_write_to_NSK({Key, {NodeID, Base+1}, undefined}, Wrt),
    add_keys_from_keylog_to_NSK(Tail, NodeID, Base+1, {Del,Wrt2}).


add_one_write_to_NSK({Key, {NodeID,Counter}, Context}, []) ->
    [{NodeID, dict:store(Counter, {Key, Context}, dict:new())}];
add_one_write_to_NSK({Key, {NodeID, Counter}, Context}, [{NodeID2, Dict}|Tail])
    when NodeID =:= NodeID2 andalso Counter =/= -1 ->
    Dict2 =  dict:store(Counter, {Key, Context}, Dict),
    [{NodeID, Dict2} | Tail];
add_one_write_to_NSK(KV={_, {NodeID,_}, _}, [H={NodeID2, _}|Tail])
    when NodeID =/= NodeID2  ->
    [H | add_one_write_to_NSK(KV, Tail)].



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%%      Recovering vnode saves multiples objects from peers
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% For recovering keys remotely after a vnode crash/failure (with lost key-values)
fill_strip_save_kvs(Objects, RemoteClock, State) ->
    fill_strip_save_kvs(Objects, RemoteClock, State, {[],[]}, true).

fill_strip_save_kvs([], _, State, {NSK, StrippedObjects}, _ETS) ->
    ok = dotted_db_storage:write_batch(State#state.storage, StrippedObjects),
    NSK;
fill_strip_save_kvs([{Key={_,_}, DCC} | Objects], RemoteClock, State, {NSK, StrippedObjects}, ETS) ->
    % fill the DCC with the sending clock
    FilledDCC = fill_clock(Key, DCC, RemoteClock),
    % removed unnecessary causality from the DCC, based on the current node clock
    StrippedDCC = {Values, Context} = dcc:strip(FilledDCC, State#state.clock),
    Values2 = [{D,V} || {D,V} <- Values, V =/= ?DELETE_OP],
    % StrippedDCC = {Values2, Context},
    % the resulting object/DCC is one of the following options:
    %   * it has no value and no causal history -> can be deleted
    %   * it has no value but has causal history -> it's a delete, but still must be persisted
    %   * has values, with causal context -> it's a normal write and we should persist
    %   * has values, but no causal context -> it's the final form for this write
    Acc = case {Values2, Context} of
        {[],[]} ->
            ETS andalso ets:insert(State#state.atom_id, {Key, 1}),
            {NSK,                       [{delete, Key}|StrippedObjects]};
        {[],_CC} ->
            ETS andalso ets:insert(State#state.atom_id, {Key, 0}),
            {[{Key, StrippedDCC}|NSK],  [{put, Key, StrippedDCC}|StrippedObjects]};
        {_ ,[]} ->
            ETS andalso ets:insert(State#state.atom_id, {Key, 3}),
            {NSK,                       [{put, Key, StrippedDCC}|StrippedObjects]};
        {_ ,_CC} ->
            ETS andalso ets:insert(State#state.atom_id, {Key, 2}),
            {[{Key, StrippedDCC}|NSK],  [{put, Key, StrippedDCC}|StrippedObjects]}
    end,
    fill_strip_save_kvs(Objects, RemoteClock, State, Acc, ETS).



is_replicated_vv_up_to_date(State) ->
    length(State#state.replicated) =:= (?REPLICATION_FACTOR-1)*2.


new_vnode_id(Index) ->
    % generate a new vnode ID for now
    <<A:32, B:32, C:32>> = crypto:rand_bytes(12),
    _ = random:seed({A,B,C}),
    % get a random index withing the length of the list
    {Index, random:uniform(999999999999)}.

create_ets_all_keys(NewVnodeID) ->
    AtomID = get_ets_id(NewVnodeID),
    _ = ((ets:info(AtomID) =:= undefined) andalso
            ets:new(AtomID, [named_table, public, set, {write_concurrency, false}])),
    AtomID.

delete_ets_all_keys(AtomID) ->
    _ = ((ets:info(AtomID) =:= undefined) andalso ets:delete(AtomID)),
    true.

sync_merge_clocks(RemoteNodeID, RemoteClockBase, State) ->
    % get current peers node ids from replicated
    CurrentPeersIds = vv:ids(State#state.replicated),
    % get peers indices
    PeerIndices = [Idx || {Idx,_} <- CurrentPeersIds],
    % filter ids from non-peer nodes
    FunFilter = fun(Id={Idx,_},_) ->
                    lists:member(Idx, PeerIndices) andalso %% filter the irrelevant
                    (not lists:member(Id, CurrentPeersIds)) %% filter the non-dead
                end,
    RemoteClockBase2 = orddict:filter(FunFilter, RemoteClockBase),
    % merge the filtered remote clock with our own clock
    NodeClock0 = bvv:merge(State#state.clock, RemoteClockBase2),
    % replace the current entry in the node clock for the responding clock with
    % the current knowledge it's receiving
    RemoteEntry = bvv:get(RemoteNodeID, RemoteClockBase),
    bvv:store_entry(RemoteNodeID, RemoteEntry, NodeClock0).

get_all_keys(State) ->
    get_written_keys(State#state.atom_id) ++ 
    get_final_written_keys(State#state.atom_id) ++
    get_issued_deleted_keys(State#state.atom_id).
