// docs.go -- the "sorting documents" benchmark, Go version.
//
// 2,000 documents and 9 category word lists, made by gen_docs.py. One
// goroutine per document reads its file and splits it into words, then
// starts one goroutine per category to count the document's words that
// are in that category. The document goes to the category with the most;
// main collects every document's category and the totals.
//
//	go build -o docs-go docs.go && ./docs-go [-linear] [trials [outfile]]
package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

const D = 2000

type category map[string]bool

func loadCategories(path string) []category {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "docs: run make data first")
		os.Exit(1)
	}
	var cs []category
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		c := category{}
		for _, w := range strings.Split(line, " ") {
			c[w] = true
		}
		cs = append(cs, c)
	}
	return cs
}

func docPath(dir string, d int) string {
	return fmt.Sprintf("%s/doc%04d.txt", dir, d)
}

func readWords(path string) []string {
	data, _ := os.ReadFile(path)
	return strings.Split(string(data), " ")
}

func count(words []string, c category) int {
	n := 0
	for _, w := range words {
		if c[w] {
			n++
		}
	}
	return n
}

// Ties go to the lower-numbered category.
func pick(counts []int) int {
	best := 0
	for i, n := range counts {
		if n > counts[best] {
			best = i
		}
	}
	return best
}

type sorted struct{ d, category int }

func sortDoc(d int, dir string, cs []category, out chan sorted) {
	words := readWords(docPath(dir, d))
	type tally struct{ i, n int }
	tallies := make(chan tally, len(cs))
	for i, c := range cs {
		go func(i int, c category) { tallies <- tally{i, count(words, c)} }(i, c)
	}
	counts := make([]int, len(cs))
	for range cs {
		t := <-tallies
		counts[t.i] = t.n
	}
	out <- sorted{d, pick(counts)}
}

func trial(dir string, cs []category, linear bool, null *bufio.Writer) time.Duration {
	t0 := time.Now()
	result := make([]int, D)
	if linear {
		for d := 0; d < D; d++ {
			words := readWords(docPath(dir, d))
			counts := make([]int, len(cs))
			for i, c := range cs {
				counts[i] = count(words, c)
			}
			result[d] = pick(counts)
		}
	} else {
		out := make(chan sorted)
		for d := 0; d < D; d++ {
			go sortDoc(d, dir, cs, out)
		}
		for i := 0; i < D; i++ {
			s := <-out
			result[s.d] = s.category
		}
	}
	totals := make([]int, len(cs))
	for d, c := range result {
		totals[c]++
		fmt.Fprintf(null, "%d %d\n", d, c)
	}
	fmt.Fprintln(null, "totals", totals)
	null.Flush()
	return time.Since(t0)
}

func main() {
	args := os.Args[1:]
	linear := len(args) > 0 && args[0] == "-linear"
	if linear {
		args = args[1:]
	}
	trials := 1
	if len(args) > 0 {
		trials, _ = strconv.Atoi(args[0])
	}
	path := "/dev/null"
	if len(args) > 1 {
		path = args[1]
	}
	f, _ := os.Create(path)
	null := bufio.NewWriter(f)
	cs := loadCategories("data/categories.txt")
	for t := 0; t < trials; t++ {
		fmt.Printf("%.1f\n", float64(trial("data/docs", cs, linear, null).Nanoseconds())/1000)
	}
}
