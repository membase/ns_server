// @author Couchbase <info@couchbase.com>
// @copyright 2015 Couchbase, Inc.
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
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path"
	"sync"
	"syscall"
	"time"
)

func stdinWatcher(cmd *exec.Cmd, childStdin io.WriteCloser, graceful bool, proxy bool) {
	b := make([]byte, 1)
	count := 0

	for {
		_, err := os.Stdin.Read(b)
		if err != nil {
			log.Printf("got %s when reading stdin; terminating.", err.Error())
			count = 0
			break
		}

		if proxy {
			if b[0] != '\n' && b[0] != '\r' {
				count = count + 1
				childStdin.Write(b)
			} else if count != 0 {
				childStdin.Write(b)
			}
		}

		if b[0] == '\n' {
			if count == 0 {
				log.Printf("got new line on a stdin; terminating.")
				break
			}
			count = 0
		}
	}

	if graceful {
		err := childStdin.Close()
		if err != nil {
			log.Fatalf("failed to close child's stdin: %s", err.Error())
		}
	} else {
		err := cmd.Process.Kill()
		if err != nil {
			log.Fatalf("failed to kill the child: %s", err.Error())
		}

		os.Exit(0)
	}
}

type throttledWriter struct {
	mu   sync.Mutex
	cond *sync.Cond

	burst     int
	available int
}

func newThrottledWriter(burst int) *throttledWriter {
	th := &throttledWriter{
		burst:     burst,
		available: burst,
	}

	th.cond = sync.NewCond(&th.mu)

	ticker := time.Tick(100 * time.Millisecond)
	go func() {
		for _ = range ticker {
			th.incAvailable((burst + 9) / 10)
		}
	}()

	return th
}

func (th *throttledWriter) incAvailable(n int) {
	th.mu.Lock()
	defer th.mu.Unlock()

	th.available += n
	if th.available > th.burst {
		th.available = th.burst
	}

	th.cond.Signal()
}

func (th *throttledWriter) decAvailable(n int) {
	th.mu.Lock()
	defer th.mu.Unlock()

	th.available -= n
}

func (th *throttledWriter) waitAvailable() int {
	th.mu.Lock()
	defer th.mu.Unlock()

	for th.available == 0 {
		th.cond.Wait()
	}

	return th.available
}

func (th *throttledWriter) Write(data []byte) (int, error) {
	written := 0
	size := len(data)

	for size > 0 {
		available := th.waitAvailable()
		if available > size {
			available = size
		}

		n, err := os.Stdout.Write(data[written : written+available])

		written += n
		size -= n

		th.decAvailable(n)

		if err != nil {
			return written, err
		}
	}

	return written, nil
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
			return fmt.Errorf("Failed to find %s in path: %s", v, err.Error())
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
	} else {
		// exited
		return status.ExitStatus()
	}
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

func main() {
	var burst int
	var gracefulShutdown bool
	var proxyStdIn bool

	var cmd string
	var args []string

	flag.IntVar(&burst, "burst", 512*1024, "burst limit")
	flag.BoolVar(&gracefulShutdown, "graceful-shutdown", false,
		"shutdown the child gracefully")
	flag.BoolVar(&proxyStdIn, "proxy-stdin", false, "proxy stdin to the child process")
	flag.Var((*cmdFlag)(&cmd), "cmd", "command to execute")
	flag.Var((*argsFlag)(&args), "args", "command arguments")
	flag.Parse()

	log.SetPrefix("[goport] ")

	if burst < 0 {
		log.Fatalf("burst can't be less than zero")
	}

	if cmd == "" {
		cmd, args = getCmdFromEnv()
	}

	p := exec.Command(cmd, args...)
	th := newThrottledWriter(burst)

	stdin, err := p.StdinPipe()
	if err != nil {
		log.Fatalf("couldn't get stdin: %s", err.Error())
	}

	p.Stdout = th
	p.Stderr = th

	err = p.Start()
	if err != nil {
		log.Fatalf("couldn't start %s: %s", p.Path, err.Error())
	}

	go stdinWatcher(p, stdin, gracefulShutdown, proxyStdIn)

	err = p.Wait()
	switch err.(type) {
	case nil:
		// process exited with exit status 0
	case *exec.ExitError:
		// process exited with non-zero exit status
	default:
		log.Fatalf("unexpected error in p.Wait(): %s", err.Error())
	}

	os.Exit(getExitStatus(p))
}
