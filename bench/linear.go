// linear.go -- the sequential Go version of the COOPER benchmark: the same
// work as 1,000 plain calls on main, no goroutines, no channels.
//
// 1,000 goroutines each take the lorem block from a channel, overwrite 5
// spots with "COOPER", and send the result back. main collects all 1,000
// and writes them to /dev/null. Goroutine i's spots are
// (i*7919 + k*104729) mod 995 for k = 0..4 -- different for each, the same
// in every version, and no shared random-number generator to fight over.
//
//	go build -o cooper-golinear linear.go && ./cooper-golinear [trials [outfile]]
package main

import (
	"bufio"
	"fmt"
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

func spot(i, k int) int {
	return (i*7919 + k*104729) % (1000 - 6 + 1)
}

func cooperize(i int, block string) string {
	s := []byte(block)
	for k := 0; k < 5; k++ {
		copy(s[spot(i, k):], "COOPER")
	}
	return string(s)
}

func trial(block string, null *bufio.Writer) time.Duration {
	t0 := time.Now()
	for i := 0; i < n; i++ {
		null.WriteString(cooperize(i, block))
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
