// @author Couchbase <info@couchbase.com>
// @copyright 2015-2017 Couchbase, Inc.
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
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path"
	"strconv"
	"syscall"
	"time"
)

const (
	childReaderBufferSize = 64 * 1024
)

type childReader struct {
	stream *bufio.Reader

	reads <-chan []byte
	err   error

	*Canceler
}

func newChildReader(stream io.Reader) *childReader {
	reads := make(chan []byte)

	cr := &childReader{
		stream:   bufio.NewReaderSize(stream, childReaderBufferSize),
		reads:    reads,
		err:      nil,
		Canceler: NewCanceler(),
	}

	go cr.loop(reads)
	return cr
}

func (cr *childReader) loop(out chan []byte) {
	defer cr.Follower().Done()

	buffer := make([]byte, childReaderBufferSize)
	for {
		done := make(chan struct {
			n   int
			err error
		}, 1)

		go func() {
			n, err := cr.stream.Read(buffer)
			done <- struct {
				n   int
				err error
			}{n, err}
			close(done)
		}()

		var err error
		select {
		case <-cr.Follower().Cancel():
			err = ErrCanceled
		case result := <-done:
			if result.n != 0 {
				cp := make([]byte, result.n)
				copy(cp, buffer)

				select {
				case out <- cp:
				case <-cr.Follower().Cancel():
					err = ErrCanceled
				}
			}

			err = result.err
		}

		if err != nil {
			cr.err = err
			close(out)
			return
		}
	}
}

type write struct {
	data [][]byte
	err  chan error
}

type writeFunc func(...[]byte) error

type writer struct {
	jobs    chan *write
	doWrite writeFunc

	*Canceler
}

func newWriter(fn writeFunc) *writer {
	w := &writer{
		jobs:     make(chan *write),
		doWrite:  fn,
		Canceler: NewCanceler(),
	}

	go w.loop()
	return w
}

func (w *writer) loop() {
	defer w.Follower().Done()

	for {
		select {
		case job := <-w.jobs:
			done := make(chan error, 1)

			go func() {
				done <- w.doWrite(job.data...)
				close(done)
			}()

			var err error
			stop := false

			select {
			case <-w.Follower().Cancel():
				err = ErrCanceled
				stop = true
			case err = <-done:
			}

			job.err <- err
			close(job.err)

			if stop {
				return
			}

		case <-w.Follower().Cancel():
			return
		}
	}
}

func (w *writer) writev(data ...[]byte) <-chan error {
	err := make(chan error, 1)
	job := &write{data, err}

	go func() {
		select {
		case w.jobs <- job:
			return
		case <-w.Follower().Cancel():
			err <- ErrCanceled
			close(err)
			// loop will call Done
		}
	}()

	return err
}

type op struct {
	name string
	arg  []byte
}

type opsReader struct {
	packetStream PacketReader

	ops <-chan *op
	err error

	*Canceler
}

func newOpsReader(stream PacketReader) *opsReader {
	ops := make(chan *op)

	or := &opsReader{
		packetStream: stream,

		ops: ops,
		err: nil,

		Canceler: NewCanceler(),
	}

	go or.loop(ops)
	return or
}

func (or *opsReader) loop(out chan *op) {
	defer or.Follower().Done()

	for {
		var packet []byte
		done := make(chan error)

		go func() {
			var err error
			packet, err = or.packetStream.ReadPacket()

			done <- err
			close(done)
		}()

		var err error

		select {
		case <-or.Follower().Cancel():
			err = ErrCanceled
		case err = <-done:
			if err == nil {
				op := or.parseOp(packet)
				select {
				case out <- op:
				case <-or.Follower().Cancel():
					err = ErrCanceled
				}
			}
		}

		if err != nil {
			or.err = err
			close(out)
			return
		}
	}
}

func (or *opsReader) parseOp(packet []byte) *op {
	switch i := bytes.IndexByte(packet, ':'); i {
	case -1:
		return &op{string(packet), nil}
	default:
		name := string(packet[0:i])
		arg := packet[i+1:]
		if len(arg) == 0 {
			arg = nil
		}

		return &op{name, arg}
	}
}

type childExitedError int

func (e childExitedError) Error() string {
	return fmt.Sprintf("child process exited with status %d", int(e))
}

func (e childExitedError) exitStatus() int {
	return int(e)
}

const (
	stdin  = "stdin"
	stdout = "stdout"
	stderr = "stderr"
)

type portSpec struct {
	cmd  string
	args []string

	windowSize       int
	gracefulShutdown bool

	interactive bool
}

type loopState struct {
	unackedBytes int

	ops       <-chan *op
	pendingOp <-chan error

	childStreams map[string]*childReader
	pendingWrite <-chan error

	childDone    <-chan error
	shuttingDown bool
}

type port struct {
	child     *exec.Cmd
	childSpec portSpec

	opsReader *opsReader

	parentWriter       *writer
	parentWriterStream *NetStringWriter

	childStdin  *writer
	childStdout *childReader
	childStderr *childReader

	stdinPipe  io.WriteCloser
	stdoutPipe io.ReadCloser
	stderrPipe io.ReadCloser

	state loopState
}

func newPort(spec portSpec) *port {
	return &port{childSpec: spec}
}

func (p *port) closeAll(files []io.Closer) {
	for _, f := range files {
		f.Close()
	}
}

func (p *port) startChild() error {
	keepFiles := ([]io.Closer)(nil)
	closeFiles := ([]io.Closer)(nil)

	defer func() {
		files := append(keepFiles, closeFiles...)
		p.closeAll(files)
	}()

	keepClose := func(keep io.Closer, close io.Closer) {
		keepFiles = append(keepFiles, keep)
		closeFiles = append(closeFiles, close)
	}

	stdinR, stdinW, err := os.Pipe()
	if err != nil {
		return err
	}
	keepClose(stdinW, stdinR)

	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		return err
	}
	keepClose(stdoutR, stdoutW)

	stderrR, stderrW, err := os.Pipe()
	if err != nil {
		return err
	}
	keepClose(stderrR, stderrW)

	child := exec.Command(p.childSpec.cmd, p.childSpec.args...)
	child.Stdin = stdinR
	child.Stdout = stdoutW
	child.Stderr = stderrW

	SetPgid(child)

	err = child.Start()
	if err != nil {
		return err
	}

	// don't close fds that we need
	keepFiles = nil

	p.child = child
	p.stdinPipe = &CloseOnce{File: stdinW}
	p.stdoutPipe = &CloseOnce{File: stdoutR}
	p.stderrPipe = &CloseOnce{File: stderrR}

	p.startChildObserver()

	return nil
}

func (p *port) startChildObserver() {
	done := make(chan error)

	go func() {
		err := p.child.Wait()
		switch err.(type) {
		case *exec.ExitError:
			err = nil
		}

		done <- err
		close(done)
	}()

	p.state.childDone = done
}

func (p *port) getChildDone() <-chan error {
	if p.state.shuttingDown {
		return nil
	}

	return p.state.childDone
}

func (p *port) terminateChild() error {
	select {
	case err := <-p.state.childDone:
		return err
	default:
	}

	// all the worker goroutines must be stopped at this point
	if p.childSpec.gracefulShutdown {
		err := p.stdinPipe.Close()
		if err != nil {
			return err
		}
	} else {
		err := Kill(p.child)
		if err != nil {
			return err
		}
	}

	return <-p.state.childDone
}

func (p *port) startWorkers() {
	packetReader := (PacketReader)(NewNetStringReader(os.Stdin))
	if p.childSpec.interactive {
		packetReader = newInteractiveReader()
	}

	p.opsReader = newOpsReader(packetReader)

	p.parentWriterStream = NewNetStringWriter(os.Stdout)
	p.parentWriter = newWriter(p.parentWriterStream.WritePacketV)

	p.childStdin = newWriter(func(data ...[]byte) error {
		for _, chunk := range data {
			_, err := p.stdinPipe.Write(chunk)
			if err != nil {
				return err
			}
		}

		return nil
	})
	p.childStdout = newChildReader(p.stdoutPipe)
	p.childStderr = newChildReader(p.stderrPipe)
}

func (p *port) terminateWorkers() {
	p.opsReader.Cancel()
	p.parentWriter.Cancel()
	p.childStdin.Cancel()
	p.childStdout.Cancel()
	p.childStderr.Cancel()

	p.opsReader.Wait()
	p.parentWriter.Wait()
	p.childStdin.Wait()
	p.childStdout.Wait()
	p.childStderr.Wait()
}

func (p *port) closePipes() {
	p.stdinPipe.Close()

	// Note that we don't close stdout and stderr. That is because we
	// might still have goroutines spawned by child readers blocked in
	// read. Internally File.Close sets fd to -1 without synchronization,
	// so it would be raceful. But files do have finilizers attached to
	// them. So we just let the runtime to close the files, once they
	// garbage collected.
	//
	// p.stdoutPipe.Close()
	// p.stderrPipe.Close()
}

func (p *port) initLoopState() {
	p.state.unackedBytes = 0
	p.state.ops = p.opsReader.ops
	p.state.pendingOp = nil

	p.state.childStreams = make(map[string]*childReader)
	p.state.childStreams[stdout] = p.childStdout
	p.state.childStreams[stderr] = p.childStderr
	p.state.pendingWrite = nil
	p.state.shuttingDown = false
}

func (p *port) getOps() <-chan *op {
	if p.state.shuttingDown {
		return nil
	}

	if p.state.pendingOp != nil {
		return nil
	}

	return p.state.ops
}

func (p *port) getChildStream(tag string) <-chan []byte {
	if p.state.shuttingDown {
		return nil
	}

	if p.state.pendingWrite != nil {
		return nil
	}

	if p.state.unackedBytes >= p.childSpec.windowSize {
		return nil
	}

	stream := p.state.childStreams[tag]
	if stream != nil {
		return stream.reads
	}

	return nil
}

func (p *port) parentSyncWrite(data ...[]byte) error {
	return <-p.parentWriter.writev(data...)
}

func (p *port) proxyChildOutput(tag string, data []byte) {
	p.state.unackedBytes += len(data)
	p.state.pendingWrite = p.doProxyChildOutput(tag, data)
}

func (p *port) doProxyChildOutput(tag string, data []byte) <-chan error {
	return p.parentWriter.writev([]byte(tag), []byte(":"), data)
}

func (p *port) flushChildStream(tag string) {
	stream := p.state.childStreams[tag]

	if stream == nil {
		return
	}

	for {
		timeout := time.After(500 * time.Millisecond)

		select {
		case data, ok := <-stream.reads:
			if !ok {
				return
			}
			<-p.doProxyChildOutput(tag, data)
		case <-timeout:
			// This shouldn't happen as long as the child
			// terminates properly. But if the child creates new
			// process group and we don't terminate all processes
			// (which we don't do at least on windows), then we'll
			// have to wait forever here.
			log.Printf("Timeout while flushing %s", tag)
			return
		}
	}
}

func (p *port) abortPendingOp() {
	if p.state.pendingOp != nil {
		p.handleOpResult(errors.New("child exited"))
	}
}

func (p *port) flushChildStreams() {
	if p.state.pendingWrite != nil {
		<-p.state.pendingWrite
		p.state.pendingWrite = nil
	}

	p.flushChildStream(stderr)
	p.flushChildStream(stdout)
}

func (p *port) handleOp(op *op) {
	var ch <-chan error

	switch op.name {
	case "ack":
		ch = p.handleAck(op.arg)
	case "write":
		ch = p.handleWrite(op.arg)
	case "close":
		ch = p.handleCloseStream(op.arg)
	case "shutdown":
		ch = p.handleShutdown()
	default:
		ch = p.handleUnknown(op.name)
	}

	p.state.pendingOp = ch
}

func (p *port) handleShutdown() <-chan error {
	ch := make(chan error, 1)

	// before we can call terminateChild we need to stop child stdin
	// worker
	p.childStdin.Cancel()
	p.childStdin.Wait()

	err := p.terminateChild()
	if err != nil {
		ch <- err
	} else {
		p.flushChildStreams()
		ch <- nil
	}

	// even if got the error from terminateChild, there's not much we can
	// do
	p.noteShuttingDown()

	return ch
}

func (p *port) handleWrite(data []byte) <-chan error {
	return p.childStdin.writev(data)
}

func (p *port) handleAck(data []byte) <-chan error {
	ch := make(chan error, 1)

	if len(data) == 0 {
		ch <- fmt.Errorf("need argument")
		return ch
	}

	count, err := strconv.Atoi(string(data))
	if err != nil {
		ch <- fmt.Errorf("invalid value '%s'", string(data))
		return ch
	}

	p.state.unackedBytes -= count
	if p.state.unackedBytes < 0 {
		p.state.unackedBytes = 0
	}

	ch <- nil
	return ch
}

func (p *port) handleCloseStream(data []byte) <-chan error {
	ch := make(chan error, 1)
	stream := string(data)

	switch stream {
	case stdin:
		p.childStdin.Cancel()
		p.childStdin.Wait()
		err := p.stdinPipe.Close()
		ch <- err
	default:
		ch <- fmt.Errorf("unknown stream '%s'", stream)
	}

	return ch
}

func (p *port) handleUnknown(cmd string) <-chan error {
	ch := make(chan error, 1)
	ch <- fmt.Errorf("unknown command '%s'", cmd)

	return ch
}

func (p *port) handleOpResult(err error) error {
	resp := "ok"
	if err != nil {
		resp = fmt.Sprintf("error:%s", err.Error())
	}

	return p.parentSyncWrite([]byte(resp))
}

func (p *port) noteOpDone() {
	p.state.pendingOp = nil
}

func (p *port) noteWriteDone() {
	p.state.pendingWrite = nil
}

func (p *port) noteShuttingDown() {
	p.state.shuttingDown = true
}

func (p *port) handleChildRead(tag string, data []byte, ok bool) error {
	if !ok {
		stream := p.state.childStreams[tag]
		err := stream.err

		if err == io.EOF {
			// stream closed
			p.state.childStreams[tag] = nil
			return nil
		}

		return fmt.Errorf("failed to read from child: %s", err.Error())
	}

	p.proxyChildOutput(tag, data)
	return nil
}

func (p *port) loop() error {
	err := p.startChild()
	if err != nil {
		return fmt.Errorf("failed to start child: %s", err.Error())
	}
	defer p.closePipes()
	defer p.terminateChild()

	p.startWorkers()
	defer p.terminateWorkers()

	p.initLoopState()
	defer p.abortPendingOp()

	// try to shudown the child gracefully first, this will attempt to
	// flush the child streams, so the workers need to be alive
	defer func() { <-p.handleShutdown() }()

	for {
		select {
		case op, ok := <-p.getOps():
			if !ok {
				if p.opsReader.err == io.EOF {
					return nil
				}

				return fmt.Errorf(
					"read failed: %s", p.opsReader.err)
			}

			p.handleOp(op)
		case err := <-p.state.pendingOp:
			p.noteOpDone()
			err = p.handleOpResult(err)
			if err != nil {
				return fmt.Errorf(
					"failed to write to parent: %s", err.Error())
			}
			if p.state.shuttingDown {
				return nil
			}
		case <-p.getChildDone():
			status := getExitStatus(p.child)
			if status == 0 {
				return nil
			}
			return childExitedError(status)
		case data, ok := <-p.getChildStream(stdout):
			err := p.handleChildRead(stdout, data, ok)
			if err != nil {
				return err
			}
		case data, ok := <-p.getChildStream(stderr):
			err := p.handleChildRead(stderr, data, ok)
			if err != nil {
				return err
			}
		case err := <-p.state.pendingWrite:
			p.noteWriteDone()
			if err != nil {
				return fmt.Errorf(
					"parent write failed: %s", err.Error())
			}
		}
	}
}

type argsFlag []string

func (args *argsFlag) String() string {
	return fmt.Sprintf("%v", *args)
}

func (args *argsFlag) Set(v string) error {
	*args = append(*args, v)
	return nil
}

type cmdFlag string

func (c *cmdFlag) String() string {
	return string(*c)
}

func (c *cmdFlag) Set(v string) error {
	if v == "" {
		return errors.New("-cmd can't be empty")
	}

	if path.IsAbs(v) {
		*c = cmdFlag(v)
	} else {
		abs, err := exec.LookPath(v)
		if err != nil {
			return fmt.Errorf("failed to find '%s' in path: %s", v, err.Error())
		}

		*c = cmdFlag(abs)
	}

	return nil
}

// different platforms define different types to represent process wait
// status, but most of them have these methods
type processStatus interface {
	Exited() bool
	Signaled() bool
	Signal() syscall.Signal
	ExitStatus() int
}

func getExitStatus(cmd *exec.Cmd) int {
	status, ok := cmd.ProcessState.Sys().(processStatus)

	if !ok {
		if cmd.ProcessState.Success() {
			return 0
		}

		return 1
	}

	if !status.Signaled() && !status.Exited() {
		panic("process neither exited nor signaled")
	}

	if status.Signaled() {
		sig := status.Signal()
		// convert to exit status the way Linux does it
		return 128 + int(sig)
	}

	// exited
	return status.ExitStatus()
}

func getCmdFromEnv() (string, []string) {
	rawArgs := os.Getenv("GOPORT_ARGS")
	if rawArgs == "" {
		log.Fatalf("GOPORT_ARGS is empty")
	}

	var args []string

	err := json.Unmarshal([]byte(rawArgs), &args)
	if err != nil {
		log.Fatalf("couldn't unmarshal GOPORT_ARGS(%s): %s", rawArgs, err.Error())
	}

	if len(args) < 1 {
		log.Fatalf("missing executable")
	}

	return args[0], args[1:]
}

type interactiveReader struct {
	scanner *bufio.Scanner
}

func newInteractiveReader() *interactiveReader {
	return &interactiveReader{bufio.NewScanner(os.Stdin)}
}

func (r *interactiveReader) ReadPacket() ([]byte, error) {
	read := r.scanner.Scan()
	if read {
		return r.scanner.Bytes(), nil
	}

	err := r.scanner.Err()
	if err != nil {
		return nil, err
	}

	return nil, io.EOF
}

func main() {
	var gracefulShutdown bool
	var windowSize int

	var cmd string
	var args []string

	var interactive bool

	flag.IntVar(&windowSize, "window-size", 64*1024, "window size")
	flag.BoolVar(&gracefulShutdown, "graceful-shutdown", false,
		"shutdown the child gracefully")
	flag.BoolVar(&interactive, "interactive", false,
		"run in interactive mode")
	flag.Var((*cmdFlag)(&cmd), "cmd", "command to execute")
	flag.Var((*argsFlag)(&args), "args", "command arguments")
	flag.Parse()

	log.SetPrefix("[goport] ")

	if windowSize < 0 {
		log.Fatalf("window size can't be less than zero")
	}

	if cmd == "" {
		cmd, args = getCmdFromEnv()
	}

	log.SetPrefix(fmt.Sprintf("[goport(%s)] ", cmd))

	port := newPort(portSpec{
		cmd:              cmd,
		args:             args,
		windowSize:       windowSize,
		gracefulShutdown: gracefulShutdown,
		interactive:      interactive,
	})

	err := port.loop()
	if err != nil {
		status := 1

		childError, ok := err.(childExitedError)
		if ok {
			status = childError.exitStatus()
		}

		log.Print(err.Error())
		os.Exit(status)
	}
}
