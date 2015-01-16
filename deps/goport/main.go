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
	"flag"
	"io"
	"log"
	"os"
	"os/exec"
	"sync"
	"time"
)

func stdinWatcher(cmd *exec.Cmd, childStdin io.Closer, graceful bool) {
	b := make([]byte, 1)

	for {
		_, err := os.Stdin.Read(b)
		if err != nil {
			log.Printf("got %s when reading stdin; terminating.", err.Error())
			break
		}

		if b[0] == '\n' || b[0] == '\r' {
			log.Printf("got new line on a stdin; terminating.")
			break
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

func readCmd() *exec.Cmd {
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

	return exec.Command(args[0], args[1:]...)
}

func main() {
	var burst int
	var gracefulShutdown bool

	flag.IntVar(&burst, "burst", 512*1024, "burst limit")
	flag.BoolVar(&gracefulShutdown, "graceful-shutdown", false,
		"shutdown the child gracefully")
	flag.Parse()

	log.SetPrefix("[goport] ")

	if burst < 0 {
		log.Fatalf("burst can't be less than zero")
	}

	cmd := readCmd()
	th := newThrottledWriter(burst)

	stdin, err := cmd.StdinPipe()
	if err != nil {
		log.Fatalf("couldn't get stdin: %s", err.Error())
	}

	go stdinWatcher(cmd, stdin, gracefulShutdown)

	cmd.Stdout = th
	cmd.Stderr = th

	err = cmd.Start()
	if err != nil {
		log.Fatalf("couldn't start %s: %s", cmd.Path, err.Error())
	}

	err = cmd.Wait()
	if err != nil {
		log.Fatalf("%s terminated: %s", cmd.Path, err.Error())
	}
}
