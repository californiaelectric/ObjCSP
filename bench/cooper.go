// cooper.go -- the Go version of the COOPER benchmark.
//
// 1,000 goroutines each take the lorem block from a channel, overwrite 5
// random spots with "COOPER", and send the result back. main collects all
// 1,000 and writes them to /dev/null.
//
//	go build -o cooper-go cooper.go && ./cooper-go [trials [outfile]]
package main

import (
	"bufio"
	"fmt"
	"math/rand"
	"os"
	"strconv"
	"strings"
	"time"
)

const n = 1000

var words = strings.Fields("lorem ipsum dolor sit amet consectetur adipiscing elit sed do " +
	"eiusmod tempor incididunt ut labore et dolore magna aliqua ut enim ad minim veniam " +
	"quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat " +
	"duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu " +
	"fugiat nulla pariatur excepteur sint occaecat cupidatat non proident sunt in culpa " +
	"qui officia deserunt mollit anim id est laborum")

// 1,000 characters of lorem ipsum, all lowercase.
func lorem() string {
	var b strings.Builder
	for i := 0; b.Len() < 1000; i++ {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(words[i%len(words)])
	}
	return b.String()[:1000]
}

func cooper(in chan string, out chan string) {
	s := []byte(<-in)
	for k := 0; k < 5; k++ {
		p := rand.Intn(len(s) - 6 + 1)
		copy(s[p:], "COOPER")
	}
	out <- string(s)
}

func trial(block string, null *bufio.Writer) time.Duration {
	t0 := time.Now()
	in := make(chan string)
	out := make(chan string)
	for i := 0; i < n; i++ {
		go cooper(in, out)
	}
	for i := 0; i < n; i++ {
		in <- block
	}
	for i := 0; i < n; i++ {
		null.WriteString(<-out)
	}
	null.Flush()
	return time.Since(t0)
}

func main() {
	trials := 1
	if len(os.Args) > 1 {
		trials, _ = strconv.Atoi(os.Args[1])
	}
	path := "/dev/null" // a file in place of /dev/null, to check the output
	if len(os.Args) > 2 {
		path = os.Args[2]
	}
	f, _ := os.Create(path)
	null := bufio.NewWriter(f)
	block := lorem()
	for t := 0; t < trials; t++ {
		fmt.Printf("%.1f\n", float64(trial(block, null).Nanoseconds())/1000)
	}
}
