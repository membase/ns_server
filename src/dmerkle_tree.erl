% Copyright (c) 2009, NorthScale, Inc
% Copyright (c) 2008, Cliff Moon
% Copyright (c) 2008, Powerset, Inc
%
% All rights reserved.
%
% Redistribution and use in source and binary forms, with or without
% modification, are permitted provided that the following conditions
% are met:
%
% * Redistributions of source code must retain the above copyright
% notice, this list of conditions and the following disclaimer.
% * Redistributions in binary form must reproduce the above copyright
% notice, this list of conditions and the following disclaimer in the
% documentation and/or other materials provided with the distribution.
% * Neither the name of Powerset, Inc nor the names of its
% contributors may be used to endorse or promote products derived from
% this software without specific prior written permission.
%
% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
% COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
% POSSIBILITY OF SUCH DAMAGE.
%
% Original Author: Cliff Moon

-module(dmerkle_tree).

-behaviour(gen_server).

-include_lib("eunit/include/eunit.hrl").

-include_lib("kernel/include/file.hrl").

%% API
-export([start_link/2, stop/1,
         tx_begin/1, tx_commit/1, tx_rollback/1,
         d/1, root/1, block_size/1, update_root/2,
         write/2, delete/2, read/2,
         read_key/2, delete_key/3, write_key/3, filename/1,
         state/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("dmerkle.hrl").
-include("common.hrl").

-record(dmerkle_tree,
        {file, size=0, virtsize=0, d, blocksize, headersize=0,
         filename, ops=[], opdict=dict:new(), freepointer=0,
         rootpointer=0, kfpointers=[], bigkfpointer=0}).

-ifdef(TEST).
-include("test/dmerkle_tree_test.erl").
-endif.

start_link(FileName, BlockSize) ->
  gen_server:start_link(dmerkle_tree, [FileName, BlockSize], []).

tx_begin(Pid) ->
  gen_server:call(Pid, tx_begin, infinity).

tx_commit(Pid) ->
  gen_server:call(Pid, tx_commit, infinity).

tx_rollback(Pid) ->
  gen_server:call(Pid, tx_rollback, infinity).

root(Pid) ->
  gen_server:call(Pid, root, infinity).

d(Pid) ->
  gen_server:call(Pid, d, infinity).

block_size(Pid) ->
  gen_server:call(Pid, block_size, infinity).

update_root(Node, Pid) ->
  gen_server:call(Pid, {update_root, Node}, infinity).

stop(Pid) ->
  gen_server:cast(Pid, close).

write(Node, Pid) ->
  gen_server:call(Pid, {write, Node}, infinity).

delete(Offset, Pid) ->
  gen_server:call(Pid, {delete, Offset}, infinity).

read(Offset, Pid) ->
  gen_server:call(Pid, {read, Offset}, infinity).

read_key(Offset, Pid) ->
  gen_server:call(Pid, {read_key, Offset}, infinity).

delete_key(Offset, Key, Pid) ->
  gen_server:call(Pid, {delete_key, Offset, Key}, infinity).

write_key(Offset, Key, Pid) ->
  gen_server:call(Pid, {write_key, Offset, Key}, infinity).

filename(Pid) ->
  gen_server:call(Pid, filename, infinity).

state(Pid) ->
  gen_server:call(Pid, state, infinity).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([FileName, BlockSize]) ->
  filelib:ensure_dir(FileName),
  {ok, File} =
        file:open(FileName, [raw, read, write, binary,
                             delayed_write, read_ahead]),
  {ok, FileInfo} = file:read_file_info(FileName),
  FileSize = FileInfo#file_info.size,
  case read_header(File) of
    {ok, Header} ->
          {ok, create_or_read_root(Header#dmerkle_tree{filename=FileName,
                                                       file=File,
                                                       size=FileSize})};
    {error, Msg} -> {stop, Msg};
    eof ->
      D = ?d_from_blocksize(BlockSize),
      HeaderSize = ?headersize_from_blocksize(BlockSize),
      Pointers = lists:map(fun(_) -> 0 end,
                           lists:seq(1,?pointers_from_blocksize(BlockSize))),
      % we want to retain passed in blocksize,
      % internal fragmentation doesn't matter.
      T = create_or_read_root(
            #dmerkle_tree{file=File,d=D,blocksize=BlockSize,
                          filename=FileName,
                          headersize=HeaderSize,size=HeaderSize,
                          kfpointers=Pointers}),
      flush(File, T#dmerkle_tree.ops),
      {ok, T#dmerkle_tree{ops=[],size=HeaderSize + BlockSize}}
  end.

terminate(_Reason, #dmerkle_tree{file=File}) ->
  % error_logger:info_msg("shutting down and closing~n"),
  ok = file:close(File).

code_change(_OldVsn, State, _Extra) -> {ok, State}.

handle_cast(close, State) -> {stop, shutdown, State}.
handle_info(_Info, State) -> {noreply, State}.

%%--------------------------------------------------------------------
%% @spec
%% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% @doc Handling call messages
%% @end
%%--------------------------------------------------------------------
handle_call(tx_begin, _From, State = #dmerkle_tree{}) ->
  {reply, ok, State#dmerkle_tree{ops=[]}};

handle_call(tx_commit, _From, State = #dmerkle_tree{ops=Ops,file=File,size=Size,virtsize=VirtSize}) ->
  % ?infoFmt("commiting btree changes to disk size ~p virtsize ~p~n operations~p~n", [Size, VirtSize, lists:reverse(Ops)]),
  case flush(File, Ops) of
    ok -> {reply, ok, State#dmerkle_tree{ops=[], opdict=dict:new(),
                                         size=Size+VirtSize, virtsize=0}};
    {error, Reasons} -> {stop, Reasons, State}
  end;

handle_call(tx_rollback, _From, State = #dmerkle_tree{}) ->
  {reply, ok, State#dmerkle_tree{ops=[], opdict=dict:new(), virtsize=0}};

handle_call(d, _From, State = #dmerkle_tree{d=D}) ->
  {reply, D, State};

handle_call(root, _From,
            State = #dmerkle_tree{rootpointer=Ptr,blocksize=BlockSize}) ->
  {reply, int_read(Ptr, BlockSize, State), State};

handle_call(block_size, _From, State = #dmerkle_tree{blocksize=BlockSize}) ->
  {reply, BlockSize, State};

handle_call({update_root, Node}, _From, State = #dmerkle_tree{}) ->
  {reply, self(),
   write_header(State#dmerkle_tree{rootpointer=offset(Node)})};

handle_call({write, Node}, _From,
            State = #dmerkle_tree{blocksize=BlockSize}) ->
  {N, T} = int_write(Node, BlockSize, State),
  {reply, N, T};

handle_call({delete, Offset}, _From, State = #dmerkle_tree{}) ->
  {reply, self(), int_delete(Offset, State)};

handle_call({read, Offset}, _From,
            State = #dmerkle_tree{blocksize=BlockSize}) ->
  {reply, int_read(Offset, BlockSize, State), State};

handle_call({read_key, Offset}, _From, State = #dmerkle_tree{}) ->
  {reply, int_read_key(Offset, State), State};

handle_call({delete_key, Offset, Key}, _From, State = #dmerkle_tree{}) ->
  {reply, self(), int_delete_key(Offset, Key, State)};

handle_call({write_key, Offset, Key}, _From, State = #dmerkle_tree{}) ->
  {Offset2, State2} = int_write_key(Offset, Key, State),
  {reply, Offset2, State2};

handle_call(filename, _From, State = #dmerkle_tree{filename=Filename}) ->
  {reply, Filename, State};

handle_call(state, _From, State) ->
  {reply, State, State}.

%%--------------------------------------------------------------------
%%% Internal functions =================READ / WRITE operations
%%--------------------------------------------------------------------
write_header(Tree = #dmerkle_tree{file=_File}) ->
  % ok = file:pwrite(File,0,serialize_header(Tree)),
  % Tree.
  {_, Tree2} = add_operation(0, serialize_header(Tree), Tree),
  Tree2.

read_header(File) ->
  %gotta get the blocksize first
  case file:pread(File, 1, 4) of
    {ok, <<BlockSize:32>>} ->
      case file:pread(File, 0, ?headersize_from_blocksize(BlockSize)) of
        {ok, Bin} -> deserialize_header(Bin);
        eof -> eof;
        {error, Msg} -> {error, Msg}
      end;
    eof -> eof;
    {error, Msg} -> {error, Msg}
  end.

int_read(0, _, _Tree) ->
  {error, "tried to read a node from the null pointer"};

int_read(Offset, BlockSize, #dmerkle_tree{file=File,d=D}) ->
    case file:pread(File, Offset, BlockSize) of
      {ok, Bin} -> deserialize(Bin, D, Offset);
      eof ->
        error_logger:info_msg("hit an eof for offset ~p", [Offset]),
        undefined;
      {error, Reason} ->
        error_logger:info_msg("error ~p at offset ~p", [Reason, Offset]),
        undefined
    end.

int_write(Node = #free{}, BlockSize, Tree) ->
  Offset = offset(Node),
  {_, Tree2} = add_operation(Offset, serialize(Node, BlockSize), Tree),
  {Node, Tree2};

int_write(Node, BlockSize, Tree = #dmerkle_tree{file=_File}) ->
  % ?infoFmt("int_write ~p~n", [Node]),
  Offset = offset(Node),
  Bin = serialize(Node, BlockSize),
  {Offset2, Tree2} = take_free_offset(Offset, Tree),
  {Offset3, Tree3} = add_operation(Offset2, Bin, Tree2),
  {offset(Node, Offset3), Tree3}.

int_delete(Offset,
           Tree = #dmerkle_tree{file=_File,blocksize=BlockSize,
                                freepointer=Pointer}) ->
  {_, Tree2} =
        int_write(#free{offset=Offset,pointer=Pointer}, BlockSize, Tree),
  write_header(Tree2#dmerkle_tree{freepointer=Offset}).

%this gotta change at some point
int_read_key(Offset,
             Tree = #dmerkle_tree{file=File,blocksize=BlockSize}) ->
  case file:pread(File, Offset, BlockSize) of
    {ok, Bin} ->
      case misc:zero_split(Bin) of
        {Key, _} -> binary_to_list(Key);
        _ -> binary_to_list(Bin) ++ int_read_key(Offset+BlockSize, Tree)
      end;
    eof -> eof;
    {error, Reason} -> {error, Reason}
  end.

int_write_key(eof, Key,
              Tree = #dmerkle_tree{size=Size,blocksize=BlockSize,
                                   kfpointers=Pointers})
  when length(Key) < BlockSize ->
  N = ?pointer_for_size(length(Key)+1, BlockSize),
  % ?infoFmt("int_write_key ~p~nN ~p~nsize ~p~n",
  %          [Key, N, ?size_for_pointer(N)]),
  case find_free_keypointer(?size_for_pointer(N), N,
                            lists:nthtail(N-1, Pointers), Tree) of
    not_found ->
      {Ptr, Tree2} = split_freespace(?size_for_pointer(N),
                                     BlockSize, Size, Tree),
      % ?infoFmt("writing key to ~p~n tree~p~n", [Ptr, Tree2]),
      add_operation(Ptr, [Key,0], Tree2);
    {Ptr, Tree2} -> add_operation(Ptr, [Key,0], Tree2)
  end;

int_write_key(Offset, Key, Tree) ->
  add_operation(Offset, [Key,0], Tree).

int_delete_key(Offset, Key,
               Tree = #dmerkle_tree{blocksize=BlockSize,
                                    kfpointers=Pointers})
  when length(Key) < BlockSize ->
  FirstN = ?pointer_for_size(length(Key)+1, BlockSize),
  % ?debugHere,
  {N, Tree2} = merge_freespace(FirstN, ?size_for_pointer(FirstN),
                               Offset, Tree),
  % ?debugHere,
  {_, Tree3} = int_write(#free{pointer=lists:nth(N, Pointers),
                               offset=Offset}, ?size_for_pointer(N), Tree2),
  % ?debugHere,
  write_header(replace_kfpointer(N, Offset, Tree3)).

%%--------------------------------
%% ============SUPPORT FUNCTIONS
%%--------------------------------
flush(File, Ops) ->
  file:pwrite(File, lists:reverse(Ops)).

find_free_keypointer(_Size, _N, [], _Tree) ->
  % ?infoMsg("find_free_keypointer not found ~n"),
  not_found;

find_free_keypointer(Size, N, [0|Pointers], Tree) ->
  % ?infoFmt("find_free_keypointer Size ~p N ~p [0 | Pointers]~n",
  %          [Size, N]),
  find_free_keypointer(Size, N+1, Pointers, Tree);

find_free_keypointer(Size, N, [Ptr|_Pointers], Tree) ->
  % ?infoFmt("find_free_keypointer found freespace Size ~p N ~p Ptr ~p~n",
  %          [Size, N, Ptr]),
  Free = int_read(Ptr, Size, Tree),
  % ?infoFmt("Free was ~p~n", Free),
  {Ptr, Tree2} = split_freespace(Size, ?size_for_pointer(N), Ptr, Tree),
  {Ptr, write_header(replace_kfpointer(N, Free#free.pointer, Tree2))}.

replace_kfpointer(N, Ptr, Tree = #dmerkle_tree{kfpointers=Pointers}) ->
  Tree#dmerkle_tree{kfpointers=misc:nthreplace(N, Ptr, Pointers)}.

merge_freespace(N, BlockSize, _Offset,
                Tree = #dmerkle_tree{blocksize=BlockSize}) ->
  % ?infoMsg("merge_freespace got whole block~n"),
  {N, Tree};

merge_freespace(N, Size, Offset,
                Tree = #dmerkle_tree{file=File,blocksize=BlockSize,
                                     headersize=HeaderSize})
  when Size < BlockSize,
       ?block(Offset, HeaderSize, BlockSize) == ?block((Offset+Size),
                                                       HeaderSize,
                                                       BlockSize) ->
  % ?infoFmt("merge_freespace N ~p Size ~p Offset ~p~n",
  %          [N, Size, Offset]),
  case file:pread(File, Offset+Size, Size) of
    {ok, <<3:8, Size:16, _/binary>>} ->
      Tree2 = remove_free_pointer(Offset+Size, N, Tree),
      merge_freespace(N+1, Size * 2, Offset, Tree2);
    {ok, _Bin} -> {N, Tree};
    eof -> {N, Tree}
  end;

merge_freespace(N, _, _, Tree) -> {N, Tree}.

remove_free_pointer(Ptr, N,
                    Tree = #dmerkle_tree{file=_File,
                                         kfpointers=Pointers}) ->
  Head = lists:nth(N, Pointers),
  Size = ?size_for_pointer(N),
  Free = case int_read(Head, Size, Tree) of
    {error, Reason} ->
      ?infoFmt("remove_free_pointer bug ~p, ~p, ~p", [Ptr, N, Tree]),
      {error, Reason};
    F -> F
  end,
  ToReplace = int_read(Ptr, Size, Tree),
  if
    Head == Ptr -> write_header(replace_kfpointer(N, ToReplace#free.pointer,
                                                  Tree));
    true -> remove_free_pointer(Free, ToReplace, Size, Tree)
  end.

remove_free_pointer(Free = #free{pointer=Ptr},
                    _ToReplace = #free{offset=Ptr,pointer=Next},
                    Size, Tree = #dmerkle_tree{file=_File}) ->
  {_, Tree2} = int_write(Free#free{pointer=Next}, Size, Tree),
  Tree2;

remove_free_pointer(_Free = #free{pointer=0}, _, _, Tree) -> Tree;

remove_free_pointer(_Free = #free{pointer=Ptr},
                    ToReplace, Size, Tree = #dmerkle_tree{file=_File}) ->
  remove_free_pointer(int_read(Ptr, Size, Tree), ToReplace, Size, Tree).

split_freespace(ReqSize, ReqSize, Ptr, Tree) ->
  {Ptr, Tree};

%this is ok because writing past the end fills with zeroes
split_freespace(ReqSize, FreeSize, Ptr,
                Tree = #dmerkle_tree{file=_File,blocksize=BlockSize,
                                     kfpointers=Pointers})
  when FreeSize > ReqSize ->
  % ?infoFmt("split_freespace reqsize ~p freesize ~p ptr ~p~n",
  %          [ReqSize, FreeSize, Ptr]),
  N = ?pointer_for_size(FreeSize div 2, BlockSize),
  NxtPtr = lists:nth(N, Pointers),
  % ?infoFmt("split_freespace writing free cell of size ~p to ~p~n",
  %          [FreeSize div 2, Ptr+(FreeSize div 2)]),
  {FreeNode, Tree2} = int_write(#free{pointer=NxtPtr,
                                      offset=Ptr+(FreeSize div 2)},
                                FreeSize div 2, Tree),
  % ?infoFmt("file size after free write ~p~n", [Tree2#dmerkle_tree.size]),
  FreePtr = offset(FreeNode),
  Tree3 = write_header(replace_kfpointer(N, FreePtr, Tree2)),
  split_freespace(ReqSize, FreeSize div 2, Ptr, Tree3).

add_operation(eof, Bin, Tree = #dmerkle_tree{file=File,size=Size}) ->
  BinSize = iolist_size(Bin),
  ok = file:pwrite(File, Size, Bin),
  {Size, Tree#dmerkle_tree{size=Size+BinSize}};

add_operation(Offset, Bin, Tree = #dmerkle_tree{file=File,size=Size}) ->
  % BinSize = iolist_size(Bin),
  ok = file:pwrite(File, Offset, Bin),
  if
    Offset == Size ->
          {Offset, Tree#dmerkle_tree{size=Size+iolist_size(Bin)}};
    Offset > Size ->
          {Offset, Tree#dmerkle_tree{size=Offset+iolist_size(Bin)}};
    true ->
          {Offset, Tree}
  end.

% add_operation(eof, Bin,
%               Tree = #dmerkle_tree{size=Size,virtsize=VirtSize,
%                                    ops=Ops,opdict=Dict}) ->
%   BinSize = true_size(Bin),
%   Offset = Size+VirtSize,
%   {Offset, Tree#dmerkle_tree{virtsize=VirtSize+BinSize,
%                              ops=[{Offset,Bin}|Ops],
%                              opdict=dict:store(Offset,Bin,Dict)}};
%
% add_operation(Offset, Bin, Tree = #dmerkle_tree{ops=Ops,opdict=Dict}) ->
%   {Offset, Tree#dmerkle_tree{ops=[{Offset,Bin}|Ops],
%                              opdict=dict:store(Offset,Bin,Dict)}}.
%
% true_size(List) when is_list(List) ->
%   lists:foldl(fun(E, Sum) -> true_size(E) + Sum end, 0, lists:flatten(List));
%
% true_size(Bin) when is_binary(Bin) ->
%   byte_size(Bin);

% true_size(_) -> 1.

create_or_read_root(Tree = #dmerkle_tree{file=_File,blocksize=BlockSize,
                                         headersize=HeaderSize,
                                         rootpointer=0}) ->
  {Root, Tree2} = int_write(#leaf{offset=HeaderSize}, BlockSize, Tree),
  % ?infoFmt("wrote root ~p~n", [Root]),
  write_header(Tree2#dmerkle_tree{rootpointer=offset(Root)});

create_or_read_root(Tree) -> Tree.

take_free_offset(eof, Tree = #dmerkle_tree{file=_File,blocksize=BlockSize,
                                           freepointer=FreePtr})
  when FreePtr > 0 ->
  Offset = FreePtr,
  #free{pointer=NewFreePointer} = int_read(FreePtr, BlockSize, Tree),
  {Offset, write_header(Tree#dmerkle_tree{freepointer=NewFreePointer})};

take_free_offset(Offset, Tree) ->
  {Offset, Tree}.

serialize_header(#dmerkle_tree{blocksize=BlockSize, freepointer=FreePtr,
                               bigkfpointer=BKFPointer,
                               rootpointer=RootPtr,
                               kfpointers=Pointers}) ->
  Preamble = <<?DMERKLE_VERSION:8, BlockSize:32, FreePtr:64,
              RootPtr:64, BKFPointer:64>>,
  FreeSpace = (?DMERKLE_STATIC_HEADER - byte_size(Preamble))*8,
  PtrBin = << <<Ptr:64>> || Ptr <- Pointers >>,
  % ?infoFmt("pointers: ~p~nptrbin~p~nfreespace~p~n",
  %          [Pointers, PtrBin, FreeSpace]),
  <<Preamble/binary, PtrBin/binary, 0:FreeSpace>>.

% this will try and match the current version,
% if it doesn't then we gotta punch out
deserialize_header(<<?DMERKLE_VERSION:8, BlockSize:32, FreePtr:64,
                    RootPtr:64, BKFPointer:64, Rest/binary>>) ->
  PointerSize = ?pointers_from_blocksize(BlockSize) * 8,
  <<PBin:PointerSize/binary, _/binary>> = Rest,
  Pointers = [Ptr || <<Ptr:64>> <= PBin],
  HeaderSize = ?headersize_from_blocksize(BlockSize),
  D = ?d_from_blocksize(BlockSize),
  {ok, #dmerkle_tree{blocksize=BlockSize,d=D,headersize=HeaderSize,
                     freepointer=FreePtr, rootpointer=RootPtr,
                     kfpointers=Pointers, bigkfpointer=BKFPointer}};

%hit the canopy
deserialize_header(BinHeader) ->
  case BinHeader of
    <<Version:8, _/binary>> ->
          {error, ?fmt("Mismatched version.  Cannot read version ~p",
                       [Version])};
    _ -> {error, "Cannot read version.  Dmerkle is corrupted."}
  end.

%node is denoted by a 0
deserialize(<<0:8, Binary/binary>>, D, Offset) ->
  KeyBinSize = D*4,
  ChildBinSize = (D+1)*12,
  <<M:32, KeyBin:KeyBinSize/binary,
   ChildBin:ChildBinSize/binary, _/binary>> = Binary,
  if
    M > D -> error_logger:info_msg("M is larger than D M ~p D ~p offset~p~n",
                                   [M, D, Offset]);
    true -> ok
  end,
  Keys = unpack_keys(M, KeyBin),
  Children = unpack_children(M+1, ChildBin),
  #node{m=M,children=Children,keys=Keys,offset=Offset};

deserialize(<<1:8, Bin/binary>>, D, Offset) ->
  ValuesBinSize = D*16,
  <<M:32, ValuesBin:ValuesBinSize/binary, _/binary>> = Bin,
  Values = unpack_values(M, ValuesBin),
  #leaf{m=M,values=Values,offset=Offset};

deserialize(<<3:8, Size:16, Pointer:64, _/binary>>, _D, Offset) ->
  #free{offset=Offset,size=Size,pointer=Pointer}.

serialize(#free{pointer=Pointer,size=Size}, BlockSize) ->
  LeftOverBits = (BlockSize - 11) * 8,
  <<3:8,Size:16,Pointer:64,0:LeftOverBits>>;

serialize(Node = #node{keys=Keys,children=Children,m=M}, BlockSize) ->
  D = ?d_from_blocksize(BlockSize),
  if
    M > D -> error_logger:info_msg("M is larger than D M ~p D ~p~n", [M, D]);
    length(Keys) == length(Children) ->
          error_logger:info_msg("There are as many children as keys for ~p~n",
                                [Node]);
    true -> ok
  end,
  KeyBin = pack_keys(Keys, D),
  ChildBin = pack_children(Children, D+1),
  LeftOverBits = (BlockSize - byte_size(KeyBin) - byte_size(ChildBin) - 5)*8,
  OutBin = <<0:8, M:32, KeyBin/binary, ChildBin/binary, 0:LeftOverBits>>,
  if
    byte_size(OutBin) /= BlockSize ->
      error_logger:info_msg(
        "outbin is wrong size! keys: ~p children: ~p m: ~p outbin ~p~n",
        [length(Keys), length(Children), M, byte_size(OutBin)]);
    true -> ok
  end,
  OutBin;

serialize(#leaf{values=Values,m=M}, BlockSize) ->
  D = ?d_from_blocksize(BlockSize),
  if
    M > D -> error_logger:info_msg("M is larger than D M ~p D ~p~n", [M, D]);
    true -> ok
  end,
  ValuesBin = pack_values(Values),
  LeftOverBits = (BlockSize - byte_size(ValuesBin) - 5)*8,
  OutBin = <<1:8, M:32, ValuesBin/binary, 0:LeftOverBits>>,
  if
    byte_size(OutBin) /= BlockSize ->
      error_logger:info_msg(
        "outbin is wrong size! values: ~p m: ~p outbin ~p~n",
        [length(Values), M, byte_size(OutBin)]);
    true -> ok
  end,
  OutBin.

pack_values(Values) ->
  << <<KeyHash:32, KeyPointer:64, ValHash:32>> || {KeyHash,KeyPointer,ValHash} <- Values >>.

pack_keys(Keys, D) ->
  Bin = << <<KeyHash:32>> || KeyHash <- Keys >>,
  BinSize = byte_size(Bin),
  LeftOverBits = D*4*8 - BinSize*8,
  <<Bin/binary, 0:LeftOverBits>>.

pack_children(Children, D) ->
  Bin = << <<ChildHash:32, ChildPtr:64>> || {ChildHash,ChildPtr} <- Children >>,
  BinSize = byte_size(Bin),
  LeftOverBits = D*12*8 - BinSize*8,
  <<Bin/binary, 0:LeftOverBits>>.

unpack_keys(M, Bin) ->
  [ KeyHash || <<KeyHash:32>> <= truncate(M*4, Bin) ].

unpack_children(M, Bin) ->
  [{ChildHash,ChildPtr} || <<ChildHash:32, ChildPtr:64>> <= truncate(M*12, Bin)].

unpack_values(M, Bin) ->
  [{KeyHash,KeyPointer,ValueHash} || <<KeyHash:32,KeyPointer:64,ValueHash:32>> <= truncate(M*16, Bin)].

truncate(Size, Bin) ->
  <<TruncBin:Size/binary, _/binary>> = Bin,
  TruncBin.

% deserialize(Bin) when byte_size(Bin) < 8 ->
%   {byte_size(Bin), eos};

% deserialize(<<NextPtr:64, Rest/binary>>) ->
%   {byte_size(Rest) + 8, NextPtr}.

offset(#leaf{offset=Offset}) -> Offset;
offset(#free{offset=Offset}) -> Offset;
offset(#node{offset=Offset}) -> Offset.

offset(Leaf = #leaf{}, Offset) -> Leaf#leaf{offset=Offset};
offset(Free = #free{}, Offset) -> Free#free{offset=Offset};
offset(Node = #node{}, Offset) -> Node#node{offset=Offset}.

