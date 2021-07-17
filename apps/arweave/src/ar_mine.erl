-module(ar_mine).

-export([
	start/1, stop/1, io_thread/1,
	validate/4, validate/3, validate_spora/9,
	min_difficulty/1, max_difficulty/0,
	min_spora_difficulty/1,
	sha384_diff_to_randomx_diff/1,
	spora_solution_hash/5,
	pick_recall_byte/3,
	get_search_space_upper_bound/1
]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_config.hrl").
-include_lib("arweave/include/ar_block.hrl").
-include_lib("arweave/include/ar_mine.hrl").

%%% A module for managing mining of blocks on the weave,

%% State record for miners.
-record(state, {
	parent,
	current_block,
	candidate_block,
	block_anchors,	% List of block hashes of the latest ?MAX_TX_ANCHOR_DEPTH blocks.
	recent_txs_map, % A map TXID -> ok of the txs of the latest ?MAX_TX_ANCHOR_DEPTH blocks.
	txs,
	timestamp,
	timestamp_refresh_timer,
	data_segment,
	data_segment_duration,
	reward_addr,
	reward_wallet_before_mining_reward = not_in_the_list,
	tags,
	diff,
	bds_base = not_generated,
	small_weave_hasher,
	stage_one_hasher,
	stage_two_hasher,
	search_space_upper_bound,
	blocks_by_timestamp = #{},
	block_index,
	io_threads,
	hashing_threads,
	session_ref
}).

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Spawns a new mining process and returns its PID.
start(Args) ->
	{CurrentB, TXs, RewardAddr, Tags, Parent, BlockAnchors, RecentTXMap, BI, IOThreads} = Args,
	CurrentHeight = CurrentB#block.height,
	CandidateB = #block{
		height = CurrentHeight + 1,
		hash_list = ?BI_TO_BHL(lists:sublist(BI, ?STORE_BLOCKS_BEHIND_CURRENT)),
		previous_block = CurrentB#block.indep_hash,
		hash_list_merkle = ar_block:compute_hash_list_merkle(CurrentB, BI),
		reward_addr = RewardAddr,
		tags = Tags
	},
	start_server(
		#state {
			parent = Parent,
			current_block = CurrentB,
			data_segment_duration = 0,
			reward_addr = RewardAddr,
			tags = Tags,
			block_anchors = BlockAnchors,
			recent_txs_map = RecentTXMap,
			candidate_block = CandidateB,
			txs = TXs,
			search_space_upper_bound = get_search_space_upper_bound(BI),
			io_threads = IOThreads,
			block_index = BI,
			session_ref = make_ref()
		}
	).

%% @doc Stop a running mining server.
stop(PID) ->
	PID ! stop.

%% @doc Validate that a given hash/nonce satisfy the difficulty requirement.
validate(BDS, Nonce, Diff, Height) ->
	BDSHash = ar_weave:hash(BDS, Nonce, Height),
	case validate(BDSHash, Diff, Height) of
		true ->
			{valid, BDSHash};
		false ->
			{invalid, BDSHash}
	end.

%% @doc Validate that a given block data segment hash satisfies the difficulty requirement.
validate(BDSHash, Diff, Height) ->
	case ar_fork:height_1_8() of
		H when Height >= H ->
			binary:decode_unsigned(BDSHash, big) > Diff;
		_ ->
			case BDSHash of
				<< 0:Diff, _/bitstring >> ->
					true;
				_ ->
					false
			end
	end.

%% @doc Validate Succinct Proof of Random Access.
validate_spora(BDS, Nonce, Timestamp, Height, Diff, PrevH, SearchSpaceUpperBound, SPoA, BI) ->
	H0 = ar_weave:hash(BDS, Nonce, Height),
	SolutionHash = spora_solution_hash(PrevH, Timestamp, H0, SPoA#poa.chunk, Height),
	case validate(SolutionHash, Diff, Height) of
		false ->
			false;
		true ->
			case pick_recall_byte(H0, PrevH, SearchSpaceUpperBound) of
				{error, weave_size_too_small} ->
					SPoA == #poa{};
				{ok, RecallByte} ->
					case ar_poa:validate(RecallByte, BI, SPoA) of
						false ->
							false;
						true ->
							{true, SolutionHash}
					end
			end
	end.

%% @doc Maximum linear difficulty.
%% Assumes using 256 bit RandomX hashes.
max_difficulty() ->
	erlang:trunc(math:pow(2, 256)).

-ifdef(DEBUG).
min_difficulty(_Height) ->
	1.
-else.
min_difficulty(Height) ->
	Diff = case Height >= ar_fork:height_1_7() of
		true ->
			case Height >= ar_fork:height_2_4() of
				true ->
					min_spora_difficulty(Height);
				false ->
					min_randomx_difficulty()
			end;
		false ->
			min_sha384_difficulty()
	end,
	case Height >= ar_fork:height_1_8() of
		true ->
			ar_retarget:switch_to_linear_diff(Diff);
		false ->
			Diff
	end.
-endif.

sha384_diff_to_randomx_diff(Sha384Diff) ->
	max(Sha384Diff + ?RANDOMX_DIFF_ADJUSTMENT, min_randomx_difficulty()).

%%%===================================================================
%%% Private functions.
%%%===================================================================

get_search_space_upper_bound(BI) ->
	SearchSpaceUpperBoundDepth = ?SEARCH_SPACE_UPPER_BOUND_DEPTH,
	case length(BI) < SearchSpaceUpperBoundDepth of
		true ->
			element(2, lists:last(BI));
		false ->
			element(2, lists:nth(SearchSpaceUpperBoundDepth, BI))
	end.

%% @doc Start the main mining server.
start_server(#state{ candidate_block = #block{ height = Height } } = S) ->
	case prepare_randomx(Height) of
		{ok, {StageOneHasher, StageTwoHasher, SmallWeaveHasher}} ->
			spawn(fun() ->
				try
					process_flag(message_queue_data, off_heap),
					S2 =
						S#state{
							stage_one_hasher = StageOneHasher,
							stage_two_hasher = StageTwoHasher,
							small_weave_hasher = SmallWeaveHasher
						},
					server(start_miners(update_txs(S2)))
				catch Type:Exception:StackTrace ->
					?LOG_ERROR(
						"event: mining_server_exception, type: ~p, exception: ~p,"
						" stacktrace: ~p",
						[Type, Exception, StackTrace]
					)
				end
			end);
		not_found ->
			?LOG_INFO([{event, mining_waiting_on_randomx_initialization}]),
			timer:sleep(10 * 1000),
			start_server(S)
	end.

%% @doc Takes a state and a set of transactions and return a new state with the
%% new set of transactions.
update_txs(
	S = #state {
		current_block = CurrentB,
		data_segment_duration = BDSGenerationDuration,
		block_anchors = BlockAnchors,
		recent_txs_map = RecentTXMap,
		reward_addr = RewardAddr,
		candidate_block = #block{ height = Height } = CandidateB,
		txs = TXs,
		blocks_by_timestamp = BlocksByTimestamp
	}
) ->
	NextBlockTimestamp = next_block_timestamp(BlocksByTimestamp, BDSGenerationDuration),
	NextDiff = calc_diff(CurrentB, NextBlockTimestamp),
	ValidTXs =
		ar_tx_replay_pool:pick_txs_to_mine({
			BlockAnchors,
			RecentTXMap,
			CurrentB#block.height,
			NextDiff,
			NextBlockTimestamp,
			ar_wallets:get(CurrentB#block.wallet_list, ar_tx:get_addresses(TXs)),
			TXs
		}),
	NewBlockSize =
		lists:foldl(
			fun(TX, Acc) ->
				Acc + TX#tx.data_size
			end,
			0,
			ValidTXs
		),
	NewWeaveSize = CurrentB#block.weave_size + NewBlockSize,
	{FinderReward, _RewardPool} =
		ar_node_utils:get_miner_reward_and_endowment_pool({
			CurrentB#block.reward_pool,
			ValidTXs,
			RewardAddr,
			NewWeaveSize,
			CandidateB#block.height,
			NextDiff,
			NextBlockTimestamp
		}),
	Addresses = [RewardAddr | ar_tx:get_addresses(ValidTXs)],
	Wallets = ar_wallets:get(CurrentB#block.wallet_list, Addresses),
	AppliedTXsWallets = ar_node_utils:apply_txs(Wallets, ValidTXs, CurrentB#block.height),
	RewardWalletBeforeMiningReward =
		case maps:get(RewardAddr, AppliedTXsWallets, not_found) of
			not_found ->
				not_in_the_list;
			{Balance, LastTX} ->
				{RewardAddr, Balance, LastTX}
		end,
	UpdatedWallets =
		ar_node_utils:apply_mining_reward(AppliedTXsWallets, RewardAddr, FinderReward),
	{ok, UpdatedRootHash} =
		ar_wallets:add_wallets(
			CurrentB#block.wallet_list,
			UpdatedWallets,
			RewardAddr,
			Height
		),
	NewCandidateB = CandidateB#block{
		txs = [TX#tx.id || TX <- ValidTXs],
		tx_root = ar_block:generate_tx_root_for_block(ValidTXs),
		block_size = NewBlockSize,
		weave_size = NewWeaveSize,
		wallet_list = UpdatedRootHash
	},
	BDSBase = ar_block:generate_block_data_segment_base(NewCandidateB),
	update_data_segment(
		S#state{
			candidate_block = NewCandidateB,
			bds_base = BDSBase,
			reward_wallet_before_mining_reward = RewardWalletBeforeMiningReward,
			txs = ValidTXs
		},
		NextBlockTimestamp,
		NextDiff
	).

%% @doc Generate a new timestamp to be used in the next block. To compensate for
%% the time it takes to generate the block data segment, adjust the timestamp
%% with the same time it took to generate the block data segment the last time.
next_block_timestamp(BlocksByTimestamp, BDSGenerationDuration) ->
	Timestamp = os:system_time(seconds) + BDSGenerationDuration,
	case maps:get(Timestamp, BlocksByTimestamp, not_found) of
		not_found ->
			Timestamp;
		_ ->
			Timestamp + 1
	end.

%% @doc Given a block calculate the difficulty to mine on for the next block.
%% Difficulty is retargeted each ?RETARGET_BlOCKS blocks, specified in ar.hrl
%% This is done in attempt to maintain on average a fixed block time.
%% @end
calc_diff(CurrentB, NextBlockTimestamp) ->
	ar_retarget:maybe_retarget(
		CurrentB#block.height + 1,
		CurrentB#block.diff,
		NextBlockTimestamp,
		CurrentB#block.last_retarget
	).

%% @doc Generate a new data_segment and update the timestamp and diff.
update_data_segment(
	S = #state {
		data_segment_duration = BDSGenerationDuration,
		current_block = CurrentB,
		blocks_by_timestamp = BlocksByTimestamp
	}
) ->
	BlockTimestamp = next_block_timestamp(BlocksByTimestamp, BDSGenerationDuration),
	Diff = calc_diff(CurrentB, BlockTimestamp),
	update_data_segment(S, BlockTimestamp, Diff).

update_data_segment(S, BlockTimestamp, Diff) ->
	#state{
		current_block = CurrentB,
		candidate_block = CandidateB,
		reward_addr = RewardAddr,
		bds_base = BDSBase,
		reward_wallet_before_mining_reward = RewardWalletBeforeMiningReward,
		txs = TXs,
		blocks_by_timestamp = BlocksByTimestamp,
		session_ref = SessionRef
	} = S,
	Height = CandidateB#block.height,
	NewLastRetarget =
		case ar_retarget:is_retarget_height(Height) of
			true -> BlockTimestamp;
			false -> CurrentB#block.last_retarget
		end,
	{MinerReward, RewardPool} =
		ar_node_utils:get_miner_reward_and_endowment_pool({
			CurrentB#block.reward_pool,
			TXs,
			RewardAddr,
			CandidateB#block.weave_size,
			Height,
			Diff,
			BlockTimestamp
		}),
	RewardWallet = case RewardWalletBeforeMiningReward of
		not_in_the_list ->
			#{};
		{Addr, Balance, LastTX} ->
			#{ Addr => {Balance, LastTX} }
	end,
	NewRewardWallet =
		case maps:get(
			RewardAddr,
			ar_node_utils:apply_mining_reward(RewardWallet, RewardAddr, MinerReward),
			not_found
		) of
			not_found ->
				#{};
			WalletData ->
				#{ RewardAddr => WalletData }
		end,
	{ok, UpdatedRootHash} =
		ar_wallets:update_wallets(
			CandidateB#block.wallet_list,
			NewRewardWallet,
			RewardAddr,
			Height
		),
	CDiff = ar_difficulty:next_cumulative_diff(
		CurrentB#block.cumulative_diff,
		Diff,
		Height
	),
	{DurationMicros, NewBDS} = timer:tc(
		fun() ->
			ar_block:generate_block_data_segment(
				BDSBase,
				CandidateB#block.hash_list_merkle,
				#{
					timestamp => BlockTimestamp,
					last_retarget => NewLastRetarget,
					diff => Diff,
					cumulative_diff => CDiff,
					reward_pool => RewardPool,
					wallet_list => UpdatedRootHash
				}
			)
		end
	),
	NewCandidateB = CandidateB#block{
		timestamp = BlockTimestamp,
		last_retarget = NewLastRetarget,
		diff = Diff,
		cumulative_diff = CDiff,
		reward_pool = RewardPool,
		wallet_list = UpdatedRootHash
	},
	BlocksByTimestamp2 =
		maps:filter(
			fun(Timestamp, _) ->
				Timestamp + 20 > BlockTimestamp
			end,
			maps:put(BlockTimestamp, {NewCandidateB, NewBDS}, BlocksByTimestamp)
		),
	NewS = S#state {
		timestamp = BlockTimestamp,
		diff = Diff,
		data_segment = NewBDS,
		data_segment_duration = round(DurationMicros / 1000000),
		candidate_block = NewCandidateB,
		blocks_by_timestamp = BlocksByTimestamp2
	},
	ets:insert(mining_state, {session, {SessionRef, BlockTimestamp}}),
	reschedule_timestamp_refresh(NewS).

reschedule_timestamp_refresh(S = #state{
	timestamp_refresh_timer = Timer,
	data_segment_duration = BDSGenerationDuration,
	txs = TXs
}) ->
	timer:cancel(Timer),
	case ?MINING_TIMESTAMP_REFRESH_INTERVAL - BDSGenerationDuration  of
		TimeoutSeconds when TimeoutSeconds =< 0 ->
			TXIDs = lists:map(fun(TX) -> TX#tx.id end, TXs),
			?LOG_WARNING([
				ar_mine,
				slow_data_segment_generation,
				{duration, BDSGenerationDuration},
				{timestamp_refresh_interval, ?MINING_TIMESTAMP_REFRESH_INTERVAL},
				{txs, lists:map(fun ar_util:encode/1, lists:sort(TXIDs))}
			]),
			self() ! refresh_timestamp,
			S#state{ timestamp_refresh_timer = no_timer };
		TimeoutSeconds ->
			case timer:send_after(TimeoutSeconds * 1000, refresh_timestamp) of
				{ok, Ref} ->
					S#state{ timestamp_refresh_timer = Ref };
				{error, Reason} ->
					?LOG_ERROR("ar_mine: Reschedule timestamp refresh failed: ~p", [Reason]),
					S
			end
	end.

%% @doc Start the workers and return the new state.
start_miners(S) ->
	ets:insert(mining_state, [
		{started_at, os:timestamp()},
		{sporas, 0},
		{kibs, 0},
		{recall_bytes_computed, 0},
		{best_hash, <<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0>>} %% TODO is there better syntax for this?
	]),
	start_hashing_threads(S).

start_hashing_threads(S) ->
	#state{
		candidate_block = #block{ timestamp = Timestamp, diff = Diff },
		current_block = #block{ indep_hash = PrevH },
		data_segment = BDS,
		small_weave_hasher = SmallWeaveHasher,
		stage_two_hasher = StageTwoHasher,
		search_space_upper_bound = SearchSpaceUpperBound,
		session_ref = SessionRef
	} = S,
	Subspaces = ?SPORA_SEARCH_SPACE_SUBSPACES_COUNT,
	SearchSubspaceSize = ?SPORA_SEARCH_SPACE_SIZE(SearchSpaceUpperBound) div Subspaces,
	case SearchSubspaceSize of
		0 ->
			Parent = self(),
			Thread = spawn(
				fun() ->
					small_weave_hashing_thread({
						Timestamp,
						Diff,
						BDS,
						PrevH,
						SearchSpaceUpperBound,
						SmallWeaveHasher,
						StageTwoHasher,
						Parent,
						SessionRef
					})
				end
			),
			S#state{ hashing_threads = [Thread] };
		_ ->
			start_hashing_threads2(S)
	end.

start_hashing_threads2(S) ->
	#state{
		current_block = #block{ indep_hash = PrevH },
		candidate_block = #block{ timestamp = Timestamp, diff = Diff, height = Height },
		data_segment = BDS,
		io_threads = IOThreads,
		stage_one_hasher = Hasher,
		stage_two_hasher = StageTwoHasher,
		search_space_upper_bound = SearchSpaceUpperBound,
		session_ref = SessionRef
	} = S,
	{ok, Config} = application:get_env(arweave, config),
	Parent = self(),
	Schedulers = erlang:system_info(schedulers_online),
	%% Keep one scheduler free to make sure the VM continues to compute file offsets from
	%% recall bytes, schedule new chunk reads, and pass fetched chunks to the hashing processors
	%% while all the dirty CPU schedulers are busy.
	StageOneThreadCount = max(0, min(Schedulers - 1, Config#config.stage_one_hashing_threads)),
	StageTwoThreadCount = Config#config.stage_two_hashing_threads,
	ThreadCount = max(0, min(Schedulers - 1, StageOneThreadCount + StageTwoThreadCount)),
	HashingThreads =
		[spawn(
			fun() ->
				process_flag(message_queue_data, off_heap),
				ShuffledIOThreads =
					lists:sort(fun(_, _) -> rand:uniform() > 0.5 end, IOThreads),
				Type =
					case N =< StageOneThreadCount of
						true ->
							stage_one_thread;
						_ ->
							stage_two_thread
					end,
				hashing_thread({
					Parent,
					PrevH,
					SearchSpaceUpperBound,
					Height,
					Timestamp,
					Diff,
					BDS,
					Hasher,
					StageTwoHasher,
					[],
					ShuffledIOThreads,
					Config#config.randomx_bulk_hashing_iterations,
					ar_mine_randomx:jit(),
					ar_mine_randomx:large_pages(),
					ar_mine_randomx:hardware_aes(),
					SessionRef
				}, Type)
			end)
			|| N <- lists:seq(1, ThreadCount)],
	S#state{ hashing_threads = HashingThreads }.

%% @doc The main mining server.
server(
	S = #state{
		txs = MinedTXs,
		current_block = #block{ indep_hash = PrevH },
		candidate_block = #block{ height = Height },
		search_space_upper_bound = SearchSpaceUpperBound,
		blocks_by_timestamp = BlocksByTimestamp,
		block_index = BI
	}
) ->
	receive
		%% Stop the mining process and all the workers.
		stop ->
			%% TODO write BestHash to disk
			[{_, BestHash}] = ets:lookup(mining_state, best_hash),
			ar:console("Best hash: ~p~n", [BestHash]),
			stop_miners(S),
			log_spora_performance();
		{solution, Nonce, H0, Timestamp, Hash} ->
			case maps:get(Timestamp, BlocksByTimestamp, not_found) of
				not_found ->
					%% A stale solution.
					server(S);
				{#block{ timestamp = Timestamp } = B, BDS} ->
					case get_spoa(H0, PrevH, SearchSpaceUpperBound) of
						not_found ->
							?LOG_WARNING([
								{event, found_chunk_but_no_proofs},
								{previous_block, ar_util:encode(PrevH)},
								{h0, ar_util:encode(H0)}
							]),
							server(S);
						SPoA ->
							case validate_spora(
								BDS,
								Nonce,
								Timestamp,
								Height,
								B#block.diff,
								PrevH,
								SearchSpaceUpperBound,
								SPoA,
								BI
							) of
								Result when Result == true orelse Result == {true, Hash} ->
									B2 =
										B#block{
											poa = SPoA,
											hash = Hash,
											nonce = Nonce
										},
									stop_miners(S),
									process_spora_solution(BDS, B2, MinedTXs, S);
								_ ->
									?LOG_ERROR([
										{event, miner_produced_invalid_spora},
										{hash, ar_util:encode(Hash)},
										{nonce, ar_util:encode(Nonce)},
										{prev_block, ar_util:encode(PrevH)},
										{segment, ar_util:encode(BDS)},
										{timestamp, Timestamp},
										{height, Height},
										{search_space_upper_bound, SearchSpaceUpperBound}
									]),
									server(S)
							end
					end
			end;
		%% The block timestamp must be reasonable fresh since it's going to be
		%% validated on the remote nodes when it's propagated to them. Only blocks
		%% with a timestamp close to current time will be accepted in the propagation.
		refresh_timestamp ->
			server(notify_hashing_threads(update_data_segment(S)));
		UnexpectedMessage ->
			?LOG_WARNING(
				"event: mining_server_got_unexpected_message, message: ~p",
				[UnexpectedMessage]
			),
			server(S)
	end.

stop_miners(S) ->
	ets:insert(mining_state, {session, {make_ref(), os:system_time(second)}}),
	stop_hashing_threads(S).

stop_hashing_threads(#state{ hashing_threads = Threads }) ->
	lists:foreach(fun(Thread) -> exit(Thread, stop) end, Threads).

notify_hashing_threads(S) ->
	#state{
		hashing_threads = Threads,
		candidate_block = #block{ timestamp = Timestamp, diff = Diff },
		data_segment = BDS,
		session_ref = SessionRef
	} = S,
	{ok, Config} = application:get_env(arweave, config),
	StageTwoThreadCount = Config#config.stage_two_hashing_threads,
	StageTwoThreads = lists:sublist(Threads, StageTwoThreadCount),
	lists:foreach(
		fun(Thread) ->
			Thread ! {update_state, Timestamp, Diff, BDS, StageTwoThreads, SessionRef}
		end,
		Threads
	),
	S.

io_thread(SearchInRocksDB) ->
	[{_, {SessionRef, SessionTimestamp}}] = ets:lookup(mining_state, session),
	receive
		{EncodedByte, H0, Nonce, HashingThread, {Timestamp, Diff, SessionRef}}
				when Timestamp + 19 > SessionTimestamp ->
			Byte = binary:decode_unsigned(EncodedByte, big),
			case read_chunk(Byte, SearchInRocksDB) of
				not_found ->
					io_thread(SearchInRocksDB);
				Chunk ->
					HashingThread ! {chunk, H0, Nonce, Timestamp, Diff, Chunk, SessionRef},
					io_thread(SearchInRocksDB)
			end;
		{'EXIT', _From, _Reason} ->
			ar_chunk_storage:close_files();
		_ ->
			io_thread(SearchInRocksDB)
	after 200 ->
		io_thread(SearchInRocksDB)
	end.

read_chunk(Byte, SearchInRocksDB) ->
	case ar_chunk_storage:get(Byte) of
		not_found ->
			case SearchInRocksDB of
				true ->
					case ar_data_sync:get_chunk(Byte + 1) of
						{ok, #{ chunk := C }} ->
							ets:update_counter(mining_state, kibs, (byte_size(C) div 1024)),
							C;
						_ ->
							not_found
					end;
				false ->
					not_found
			end;
		Reply ->
			ets:update_counter(mining_state, kibs, 256),
			Reply
	end.

small_weave_hashing_thread(Args) ->
	{
		Timestamp,
		Diff,
		BDS,
		PrevH,
		SearchSpaceUpperBound,
		Hasher,
		StageTwoHasher,
		Parent,
		SessionRef
	} = Args,
	receive
		{update_state, Timestamp2, Diff2, BDS2, _Threads, SessionRef} ->
			small_weave_hashing_thread({
				Timestamp2,
				Diff2,
				BDS2,
				PrevH,
				SearchSpaceUpperBound,
				Hasher,
				StageTwoHasher,
				Parent,
				SessionRef
			})
	after 0 ->
		Nonce = crypto:strong_rand_bytes(32),
		H0 = Hasher(<< Nonce/binary, BDS/binary >>),
		TimestampBinary = << Timestamp:(?TIMESTAMP_FIELD_SIZE_LIMIT * 8) >>,
		Preimage = [H0, PrevH, TimestampBinary, <<>>],
		case StageTwoHasher(Diff, Preimage) of
			{true, Hash} ->
				ets:update_counter(mining_state, sporas, 1),
				Parent ! {solution, Nonce, H0, Timestamp, Hash},
				small_weave_hashing_thread(Args);
			{false, BestHash} ->
				% TODO send BestHash to another process so best WSPoRA can be kept
				ets:insert(mining_state, {best_hash, BestHash}),
				small_weave_hashing_thread(Args);
			false ->
				small_weave_hashing_thread(Args)
		end
	end.

hashing_thread(S, Type) ->
	{
		Parent,
		PrevH,
		SearchSpaceUpperBound,
		Height,
		Timestamp,
		Diff,
		BDS,
		Hasher,
		StageTwoHasher,
		StageTwoThreads,
		IOThreads,
		HashingIterations,
		JIT,
		LargePages,
		HardwareAES,
		SessionRef
	} = S,
	T = case Type of stage_one_thread -> 0; stage_two_thread -> 200 end,
	receive
		{chunk, H0, Nonce, Timestamp2, Diff2, Chunk, SessionRef}
				when Timestamp2 + 19 > Timestamp ->
			TimestampBinary = << Timestamp2:(?TIMESTAMP_FIELD_SIZE_LIMIT * 8) >>,
			Preimage = [H0, PrevH, TimestampBinary, Chunk],
			case StageTwoHasher(Diff2, Preimage) of
				{true, Hash} ->
					Parent ! {solution, Nonce, H0, Timestamp2, Hash};
				{false, NewBestHash} ->
					% TODO send BestHash to another process so best WSPoRA can be kept
					ets:insert(mining_state, {best_hash, NewBestHash}),
					ok;
				false ->
					ok
			end,
			ets:update_counter(mining_state, sporas, 1),
			hashing_thread(S, Type);
		{update_state, Timestamp2, Diff2, BDS2, StageTwoThreads2, SessionRef} ->
			hashing_thread({
				Parent,
				PrevH,
				SearchSpaceUpperBound,
				Height,
				Timestamp2,
				Diff2,
				BDS2,
				Hasher,
				StageTwoHasher,
				StageTwoThreads2,
				IOThreads,
				HashingIterations,
				JIT,
				LargePages,
				HardwareAES,
				SessionRef
			}, Type);
		_ ->
			hashing_thread(S, Type)
	after T ->
		case Type of
			stage_one_thread when StageTwoThreads /= [] ->
				Nonce1 = crypto:strong_rand_bytes(256 div 8),
				Nonce2 = crypto:strong_rand_bytes(256 div 8),
				Ref = {Timestamp, Diff, SessionRef},
				ok = Hasher(
					Nonce1,
					Nonce2,
					BDS,
					PrevH,
					SearchSpaceUpperBound,
					IOThreads,
					StageTwoThreads,
					HashingIterations,
					JIT,
					LargePages,
					HardwareAES,
					Ref
				),
				ets:update_counter(mining_state, recall_bytes_computed, HashingIterations);
			_ ->
				ok
		end,
		hashing_thread({
			Parent,
			PrevH,
			SearchSpaceUpperBound,
			Height,
			Timestamp,
			Diff,
			BDS,
			Hasher,
			StageTwoHasher,
			StageTwoThreads,
			IOThreads,
			HashingIterations,
			JIT,
			LargePages,
			HardwareAES,
			SessionRef
		}, Type)
	end.

get_spoa(H0, PrevH, SearchSpaceUpperBound) ->
	case pick_recall_byte(H0, PrevH, SearchSpaceUpperBound) of
		{error, weave_size_too_small} ->
			#poa{};
		{ok, RecallByte} ->
			case ar_poa:get_poa_from_v2_index(RecallByte) of
				not_found ->
					not_found;
				SPoA ->
					SPoA
			end
	end.

log_spora_performance() ->
	[{_, StartedAt}] = ets:lookup(mining_state, started_at),
	Time = timer:now_diff(os:timestamp(), StartedAt),
	case Time < 10000000 of
		true ->
			ar:console("Skipping hashrate report, the round lasted less than 10 seconds.~n"),
			?LOG_INFO([
				{event, stopped_mining},
				{round_time_seconds, Time div 1000000}
			]),
			ok;
		false ->
			[{_, RecallBytes}] = ets:lookup(mining_state, recall_bytes_computed),
			[{_, KiBs}] = ets:lookup(mining_state, kibs),
			[{_, SPoRAs}] = ets:lookup(mining_state, sporas),
			RecallByteRate = RecallBytes / (Time / 1000000),
			Rate = SPoRAs / (Time / 1000000),
			ReadRate = KiBs / 1024 / (Time / 1000000),
			prometheus_histogram:observe(mining_rate, Rate),
			?LOG_INFO([
				{event, stopped_mining},
				{recall_bytes_computed, RecallByteRate},
				{miner_sporas_per_second, Rate},
				{miner_read_mibibytes_per_second, ReadRate},
				{round_time_seconds, Time div 1000000}
			]),
			ar:console(
				"Miner spora rate: ~B h/s, recall bytes computed/s: ~B, MiB/s read: ~B,"
				" the round lasted ~B seconds.~n",
				[trunc(Rate), trunc(RecallByteRate), trunc(ReadRate), Time div 1000000]
			)
	end.

process_spora_solution(BDS, B, MinedTXs, S) ->
	#state {
		parent = Parent,
		current_block = #block{ indep_hash = CurrentBH }
	} = S,
	SPoA = B#block.poa,
	IndepHash = ar_weave:indep_hash(BDS, B#block.hash, B#block.nonce, SPoA),
	B2 = B#block{ indep_hash = IndepHash },
	Parent ! {work_complete, CurrentBH, B2, MinedTXs, BDS, SPoA},
	log_spora_performance().

prepare_randomx(Height) ->
	case ar_randomx_state:randomx_state_by_height(Height) of
		{state, {fast, FastState}} ->
			%% Use RandomX fast-mode, where hashing is fast but initialization is slow.
			StageOneHasher =
				fun(
					Nonce1,
					Nonce2,
					BDS,
					PrevH,
					UpperBound,
					PIDs,
					ProxyPIDs,
					Iterations,
					JIT,
					LargePages,
					HardwareAES,
					Ref
				) ->
					ar_mine_randomx:bulk_hash_fast(
						FastState,
						Nonce1,
						Nonce2,
						BDS,
						PrevH,
						UpperBound,
						PIDs,
						ProxyPIDs,
						Iterations,
						JIT,
						LargePages,
						HardwareAES,
						Ref
					)
				end,
			StageTwoHasher =
				fun(Diff, Preimage) ->
					[{_, BestHash}] = ets:lookup(mining_state, best_hash),
					ar_mine_randomx:hash_fast_verify(FastState, Diff, BestHash, Preimage)
				end,
			SmallWeaveHasher =
				fun(Preimage) ->
					ar_mine_randomx:hash_fast(FastState, Preimage)
				end,
			{ok, {StageOneHasher, StageTwoHasher, SmallWeaveHasher}};
		{state, {light, _}} ->
			not_found;
		{key, _} ->
			not_found
	end.

pick_recall_byte(H, PrevH, SearchSpaceUpperBound) ->
	Subspaces = ?SPORA_SEARCH_SPACE_SUBSPACES_COUNT,
	SubspaceNumber = binary:decode_unsigned(H, big) rem Subspaces,
	EvenSubspaceSize = SearchSpaceUpperBound div Subspaces,
	SearchSubspaceSize = ?SPORA_SEARCH_SPACE_SIZE(SearchSpaceUpperBound) div Subspaces,
	case SearchSubspaceSize of
		0 ->
			{error, weave_size_too_small};
		_ ->
			SubspaceStart = SubspaceNumber * EvenSubspaceSize,
			SubspaceSize = min(SearchSpaceUpperBound - SubspaceStart, EvenSubspaceSize),
			EncodedSubspaceNumber = binary:encode_unsigned(SubspaceNumber),
			SearchSubspaceSeed =
				binary:decode_unsigned(
					crypto:hash(sha256, << PrevH/binary, EncodedSubspaceNumber/binary >>),
					big
				),
			SearchSubspaceStart = SearchSubspaceSeed rem SubspaceSize,
			SearchSubspaceByteSeed = binary:decode_unsigned(crypto:hash(sha256, H), big),
			SearchSubspaceByte = SearchSubspaceByteSeed rem SearchSubspaceSize,
			{ok, SubspaceStart + (SearchSubspaceStart + SearchSubspaceByte) rem SubspaceSize}
	end.

spora_solution_hash(PrevH, Timestamp, H0, Chunk, Height) ->
	ar_randomx_state:hash(
		Height,
		<< H0/binary, PrevH/binary, Timestamp:(?TIMESTAMP_FIELD_SIZE_LIMIT * 8), Chunk/binary >>
	).

-ifdef(DEBUG).
min_randomx_difficulty() -> 1.
-else.
min_randomx_difficulty() -> min_sha384_difficulty() + ?RANDOMX_DIFF_ADJUSTMENT.
min_sha384_difficulty() -> 31.
-endif.

min_spora_difficulty(Height) ->
	?SPORA_MIN_DIFFICULTY(Height).

%% Tests

%% @doc Test that found nonces abide by the difficulty criteria.
basic_test_() ->
	{timeout, 20, fun test_basic/0}.

test_basic() ->
	[B0] = ar_weave:init([]),
	ar_test_node:start(B0),
	ar_node:mine(),
	BI = ar_test_node:wait_until_height(1),
	B1 = ar_test_node:read_block_when_stored(hd(BI)),
	Threads = maps:get(io_threads, sys:get_state(ar_node_worker)),
	start({B1, [], unclaimed, [], self(), [], #{}, BI, Threads}),
	assert_mine_output(B1, B1#block.poa, []).

%% @doc Ensure that the block timestamp gets updated regularly while mining.
timestamp_refresh_test_() ->
	{timeout, 60, fun test_timestamp_refresh/0}.

test_timestamp_refresh() ->
	%% Start mining with a high enough difficulty, so that the block
	%% timestamp gets refreshed at least once. Since we might be unlucky
	%% and find the block too fast, we retry until it succeeds.
	[B0] = ar_weave:init([], ar_retarget:switch_to_linear_diff(18)),
	ar_test_node:start(B0),
	B = B0,
	Threads = maps:get(io_threads, sys:get_state(ar_node_worker)),
	Run = fun(_) ->
		TXs = [],
		StartTime = os:system_time(seconds),
		POA = #poa{},
		start({
			B,
			TXs,
			unclaimed,
			[],
			self(),
			[],
			#{},
			[ar_util:block_index_entry_from_block(B0)],
			Threads
		}),
		{_, MinedTimestamp} = assert_mine_output(B, POA, TXs),
		MinedTimestamp > StartTime + ?MINING_TIMESTAMP_REFRESH_INTERVAL
	end,
	?assert(lists:any(Run, lists:seq(1, 20))).

%% @doc Ensures ar_mine can be started and stopped.
start_stop_test_() ->
	{timeout, 20, fun test_start_stop/0}.

test_start_stop() ->
	[B] = ar_weave:init(),
	{_Node, _} = ar_test_node:start(B),
	BI = ar_test_node:wait_until_height(0),
	HighDiff = ar_retarget:switch_to_linear_diff(30),
	Threads = maps:get(io_threads, sys:get_state(ar_node_worker)),
	PID = start({B#block{ diff = HighDiff }, [], unclaimed, [], self(), [], #{}, BI, Threads}),
	timer:sleep(500),
	assert_alive(PID),
	stop(PID),
	assert_not_alive(PID, 3000).

assert_mine_output(B, POA, TXs) ->
	receive
		{work_complete, BH, NewB, MinedTXs, BDS, POA} ->
			?assertEqual(BH, B#block.indep_hash),
			?assertEqual(lists:sort(TXs), lists:sort(MinedTXs)),
			BDS = ar_block:generate_block_data_segment(NewB),
			case NewB#block.height >= ar_fork:height_2_4() of
				true ->
					#block{
						height = Height,
						previous_block = PrevH,
						timestamp = Timestamp,
						nonce = Nonce,
						poa = #poa{ chunk = Chunk }
					} = NewB,
					H0 = ar_randomx_state:hash(Height, << Nonce/binary, BDS/binary >>),
					?assertEqual(
						spora_solution_hash(PrevH, Timestamp, H0, Chunk, Height),
						NewB#block.hash
					);
				false ->
					?assertEqual(
						ar_weave:hash(BDS, NewB#block.nonce, B#block.height),
						NewB#block.hash
					)
			end,
			?assert(binary:decode_unsigned(NewB#block.hash) > NewB#block.diff),
			{NewB#block.diff, NewB#block.timestamp}
	after 20000 ->
		error(timeout)
	end.

assert_alive(PID) ->
	?assert(is_process_alive(PID)).

assert_not_alive(PID, Timeout) ->
	Do = fun () -> not is_process_alive(PID) end,
	?assert(ar_util:do_until(Do, 50, Timeout)).
