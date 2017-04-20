// @author Couchbase <info@couchbase.com>
// @copyright 2017 Couchbase, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"sync"
)

var (
	ErrInvalidNetString = errors.New("invalid netstring data")
)

type PacketReader interface {
	ReadPacket() ([]byte, error)
}

type NetStringReader struct {
	reader *bufio.Reader
}

func NewNetStringReader(r io.Reader) *NetStringReader {
	return &NetStringReader{bufio.NewReader(r)}
}

func (n *NetStringReader) ReadPacket() ([]byte, error) {
	rawLength, err := n.reader.ReadSlice(':')
	switch err {
	case nil:
		// ok
	case bufio.ErrBufferFull:
		// we couldn't find the colon before buffer filled in;
		// consider this an invalid input
		return nil, ErrInvalidNetString
	default:
		return nil, err
	}

	var length uint
	_, err = fmt.Sscanf(strings.TrimSpace(string(rawLength)), "%9d:", &length)
	if err != nil {
		return nil, ErrInvalidNetString
	}

	toRead := int(length) + 1
	packet := make([]byte, toRead)
	read, err := io.ReadFull(n.reader, packet)

	switch {
	case read != toRead && err != nil:
		return nil, err
	case read != toRead:
		return nil, ErrInvalidNetString
	case packet[length] != ',':
		return nil, ErrInvalidNetString
	default:
		// err might EOF, which is normal
		return packet[:length], err
	}
}

type NetStringWriter struct {
	writer *bufio.Writer
}

func NewNetStringWriter(w io.Writer) *NetStringWriter {
	return &NetStringWriter{bufio.NewWriter(w)}
}

func (n *NetStringWriter) WritePacket(data []byte) error {
	return n.WritePacketV(data)
}

func (n *NetStringWriter) WritePacketV(data ...[]byte) error {
	totalLen := 0
	for _, chunk := range data {
		totalLen += len(chunk)
	}

	_, err := n.writer.WriteString(strconv.Itoa(totalLen))
	if err != nil {
		return err
	}

	err = n.writer.WriteByte(':')
	if err != nil {
		return err
	}

	for _, chunk := range data {
		_, err = n.writer.Write(chunk)
		if err != nil {
			return err
		}
	}

	_, err = n.writer.WriteString(",\n")
	if err != nil {
		return err
	}

	err = n.writer.Flush()
	if err != nil {
		return err
	}

	return nil
}

var (
	ErrCanceled = errors.New("canceled")
)

type Canceler struct {
	cancel     chan struct{}
	cancelOnce *sync.Once

	done     chan struct{}
	doneOnce *sync.Once
}

type CancelFollower Canceler

func NewCanceler() *Canceler {
	return &Canceler{
		cancel:     make(chan struct{}),
		cancelOnce: &sync.Once{},

		done:     make(chan struct{}),
		doneOnce: &sync.Once{},
	}
}

func (c *Canceler) Cancel() {
	c.cancelOnce.Do(func() { close(c.cancel) })
}

func (c *Canceler) Wait() {
	<-c.done
}

func (c *Canceler) Follower() *CancelFollower {
	return (*CancelFollower)(c)
}

func (f *CancelFollower) Done() {
	f.doneOnce.Do(func() { close(f.done) })
}

func (f *CancelFollower) Cancel() <-chan struct{} {
	return f.cancel
}

type CloseOnce struct {
	*os.File
	once sync.Once
}

func (c *CloseOnce) Close() error {
	var err error
	c.once.Do(func() { err = c.File.Close() })

	return err
}
