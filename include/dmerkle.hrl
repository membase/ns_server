% Copyright (c) 2008, Cliff Moon
% Copyright (c) 2008, Powerset, Inc
% Copyright (c) 2009, NorthScale, Inc
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

-define(VERSION, 2).
-define(STATIC_HEADER, 93).

-define(d_from_blocksize(BlockSize), trunc((BlockSize - 17)/16)).
-define(pointers_from_blocksize(BlockSize),
        (misc:ceiling(math:log(BlockSize)/math:log(2)) - 3)).
-define(pointer_for_size(Size, BlockSize),
        (if Size =< 16 -> 1;
            Size =< BlockSize -> ?pointers_from_blocksize(Size);
            true -> last end)).
-define(size_for_pointer(N), (2 bsl (N+2))).
-define(headersize_from_blocksize(BlockSize),
        (?STATIC_HEADER + ?pointers_from_blocksize(BlockSize) * 8)).
-define(aligned(Ptr, HeaderSize, BlockSize),
        (((Ptr - (HeaderSize)) rem BlockSize) == 0)).
-define(block(Ptr, HeaderSize, BlockSize),
        ((Ptr - (HeaderSize)) div BlockSize)).

-record(node, {m=0, keys=[], children=[], offset=eof}).
-record(leaf, {m=0, values=[], offset=eof}).
-record(free, {offset, size=0, pointer=0}).
