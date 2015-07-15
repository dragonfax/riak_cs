%% ---------------------------------------------------------------------
%%
%% Copyright (c) 2007-2014 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------

-module(riak_cs_console).

-export([
         status/1,
         cluster_info/1,
         cleanup_orphan_multipart/0,
         cleanup_orphan_multipart/1
        ]).

-export([resolve_siblings/3]).

-include("riak_cs.hrl").
-include_lib("riakc/include/riakc.hrl").

%%%===================================================================
%%% Public API
%%%===================================================================

status([]) ->
    Stats = riak_cs_stats:get_stats(),
    [io:format("~p : ~p~n", [Name, Value])
     || {Name, Value} <- Stats].

%% in progress.
cluster_info([OutFile]) ->
    try
        case cluster_info:dump_local_node(OutFile) of
            [ok] -> ok;
            Result ->
                io:format("Cluster_info failed ~p~n", [Result]),
                error
        end
    catch
        error:{badmatch, {error, eacces}} ->
            io:format("Cluster_info failed, permission denied writing to ~p~n", [OutFile]);
        error:{badmatch, {error, enoent}} ->
            io:format("Cluster_info failed, no such directory ~p~n", [filename:dirname(OutFile)]);
        error:{badmatch, {error, enotdir}} ->
            io:format("Cluster_info failed, not a directory ~p~n", [filename:dirname(OutFile)]);
        Exception:Reason ->
            lager:error("Cluster_info failed ~p:~p",
                [Exception, Reason]),
            io:format("Cluster_info failed, see log for details~n"),
            error
    end.

%% @doc This function is for operation, esp cleaning up multipart
%% uploads which not completed nor aborted, and after that - bucket
%% deleted. Due to riak_cs/#475, this had been possible and Riak CS
%% which has been running earlier versions before 1.4.x may need this
%% cleanup.  This functions takes rather long time, because it
%% 1. iterates all existing and deleted buckets in moss.buckets
%% 2. if the bucket is deleted then search for all uncompleted
%%    multipart uploads.
%% usage:
%% $ riak-cs attach
%% 1> riak_cs_console:cleanup_orphan_multipart().
%% cleaning up with timestamp 2014-05-11-....
-spec cleanup_orphan_multipart() -> no_return().
cleanup_orphan_multipart() ->
    cleanup_orphan_multipart([]).

-spec cleanup_orphan_multipart(string()|binary()) -> no_return().
cleanup_orphan_multipart([]) ->
    cleanup_orphan_multipart(riak_cs_wm_utils:iso_8601_datetime());
cleanup_orphan_multipart(Timestamp) when is_list(Timestamp) ->
    cleanup_orphan_multipart(list_to_binary(Timestamp));
cleanup_orphan_multipart(Timestamp) when is_binary(Timestamp) ->

    {ok, RcPid} = riak_cs_riak_client:start_link([]),
    _ = lager:info("cleaning up with timestamp ~s", [Timestamp]),
    _ = io:format("cleaning up with timestamp ~s", [Timestamp]),
    Fun = fun(RcPidForOneBucket, BucketName, GetResult, Acc0) ->
                  ok = maybe_cleanup_csbucket(RcPidForOneBucket, BucketName,
                                              GetResult, Timestamp),
                  Acc0
          end,
    _ = riak_cs_bucket:fold_all_buckets(Fun, [], RcPid),

    ok = riak_cs_riak_client:stop(RcPid),
    _ = lager:info("All old unaborted orphan multipart uploads have been deleted.", []),
    _ = io:format("~nAll old unaborted orphan multipart uploads have been deleted.~n", []).


%% @doc Resolve siblings as quick operation. Assuming login via
%% `riak-cs attach` RawKey and RawBucket should be provided via Riak
%% log. Example usage is:
%%
%% > {ok, Pid} = riakc_pb_socket:start_link(Host, Port).
%% > riak_cs_console:resolve_siblings(Pid, <<...>>, <<...>>).
%% > riakc_pb_socket:stop(Pid).
%%
%% Note: this does not support multibag itself
-spec resolve_siblings(pid(), RawBucket::binary(), RawKey::binary()) -> ok | {error, term()}.
resolve_siblings(Pid, RawBucket, RawKey) ->
    GetOptions = [{r, all}],
    _ = lager:info("Trying to resolve siblings of ~p:~p", [RawBucket, RawKey]),
    case riakc_pb_socket:get(Pid, RawBucket, RawKey, GetOptions, ?DEFAULT_RIAK_TIMEOUT) of
        {ok, RiakObj} ->
            case resolve_ro_siblings(RiakObj, RawBucket, RawKey) of
                {ok, RiakObj2} ->
                    riakc_pb_socket:put(Pid, RiakObj2);
                {error, R} = E ->
                    io:format("Not updating: ~p", [R]),
                    E
            end;
        {error, Reason} = E ->
            io:format("Failed to get an object before resolution: ~p", [Reason]),
            E
    end.

-spec resolve_ro_siblings(riakc_obj:riakc_obj(), binary(), binary()) ->
                                 {ok, riakc_obj:riakc_obj()} | {error, term()}.
resolve_ro_siblings(_, ?USER_BUCKET, _) ->
    %% This is not supposed to happen unless something is messed up
    %% with Stanchion. Resolve logic is not obvious and needs operator decision.
    {error, {not_supported, ?USER_BUCKET}};
resolve_ro_siblings(_, ?ACCESS_BUCKET, _) ->
    %% To support access bucket, JSON'ized data should change its data
    %% structure to G-set, or map(register -> P-counter)
    {error, {not_supported, ?ACCESS_BUCKET}};
resolve_ro_siblings(_, ?STORAGE_BUCKET, _) ->
    %% Storage bucket access conflict resolution is not obvious; maybe
    %% adopt max usage on each buckets.
    {error, {not_supported, ?STORAGE_BUCKET}};
resolve_ro_siblings(_, ?BUCKETS_BUCKET, _) ->
    %% Bucket conflict resolution obvious, referring to all users
    %% described in value and find out who's true user. If multiple
    %% users are owner (that cannot happen unless Stanchion is messed
    %% up), operator must choose who is true owner.
    {error, {not_supported, ?BUCKETS_BUCKET}};
resolve_ro_siblings(RO, ?GC_BUCKET, _) ->
    Resolved = riak_cs_gc:decode_and_merge_siblings(RO, twop_set:new()),
    Obj = riak_cs_utils:update_obj_value(RO,
                                         riak_cs_utils:encode_term(Resolved)),
    {ok, Obj};
resolve_ro_siblings(RO, <<"0b:", _/binary>>, _) ->
    case riak_cs_utils:resolve_robj_siblings(riakc_obj:get_contents(RO)) of
        {{MD, Value}, true} when is_binary(Value) ->
            RO1 = riakc_obj:update_metadata(RO, MD),
            {ok, riakc_obj:update_value(RO1, Value)};
        {E, true} ->
            io:format("Cannot resolve: ~p", [E]),
            {error, E};
        {E, false} ->
            {error, E}
    end;
resolve_ro_siblings(RiakObject, <<"0o:", _/binary>>, _RawKey) ->
    [{_, Manifest}|_] = Manifests =
        riak_cs_manifest:manifests_from_riak_object(RiakObject),
    io:format("Value Count: ~p. Length : ~p.~n",
              [riakc_obj:value_count(RiakObject), length(Manifests)]),
    ObjectToWrite0 = riak_cs_utils:update_obj_value(
                       RiakObject, riak_cs_utils:encode_term(Manifests)),

    {B, K} = Manifest?MANIFEST.bkey,
    RO = riak_cs_manifest_fsm:update_md_with_multipart_2i(ObjectToWrite0, Manifests, B, K),
    {ok, RO}.

%%%===================================================================
%%% Internal functions
%%%===================================================================


-spec maybe_cleanup_csbucket(riak_client(),
                             binary(),
                             {ok, riakc_obj()}|{error, term()},
                             binary()) -> ok | {error, term()}.
maybe_cleanup_csbucket(RcPidForOneBucket, BucketName, {ok, RiakObj}, Timestamp) ->
    case riakc_obj:get_values(RiakObj) of
        [?FREE_BUCKET_MARKER] ->
            %% deleted bucket, ensure if no uploads exists
            io:format("\rchecking bucket ~s:", [BucketName]),
            case riak_cs_bucket:delete_old_uploads(BucketName, RcPidForOneBucket,
                                                   Timestamp) of
                {ok, 0} -> ok;
                {ok, Count} ->  io:format(" aborted ~p uploads.~n",
                                          [Count]);
                Error ->
                    lager:warning("Error in deleting old uploads: ~p~n", [Error]),
                    io:format("Error in deleting old uploads: ~p <<< ~n", [Error]),
                    Error
            end;

        [<<>>] -> %% tombstone, can't happen
            io:format("tombstone found on bucket ~s~n", [BucketName]),
            ok;
        [_] -> %% active bucket, do nothing
            ok;
        L when is_list(L) andalso length(L) > 1 -> %% siblings!! whoa!!
            io:format("siblings found on bucket ~s~n", [BucketName]),
            ok
    end;
maybe_cleanup_csbucket(_, _, {error, notfound}, _) ->
    ok;
maybe_cleanup_csbucket(_, BucketName, {error, _} = Error, _) ->
    lager:error("~p on processing ~s", [Error, BucketName]),
    io:format("Error: ~p on processing ~s\n", [Error, BucketName]),
    Error.
