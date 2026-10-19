// models.go -- the "many small models" benchmark, Go version.
//
// K independent linear classifiers over one generated dataset of S samples
// by F features. Each model's labels come from a hidden linear rule of its
// own. One goroutine per model trains it for E passes, a few milliseconds
// of arithmetic each; main collects every model's mistakes in its last pass
// and the sum of its weights, and writes them out in model order.
//
//	go build -o models-go models.go && ./models-go [trials [outfile]]
//	add -linear for the same work as plain calls on main
package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"time"
)

const (
	S = 400  // samples
	F = 256  // features
	K = 1000 // models
	E = 10   // training passes
)

// The same generator as models.h, so both make the same data.
type rng uint64

func (r *rng) next() float64 {
	*r = *r*6364136223846793005 + 1442695040888963407
	return float64(uint64(*r)>>11)/(1<<53)*2 - 1
}

func makeData() (x, y []float64) {
	r := rng(42)
	x = make([]float64, S*F)
	for i := range x {
		x[i] = r.next()
	}
	y = make([]float64, K*S)
	h := make([]float64, F)
	for k := 0; k < K; k++ {
		for f := range h {
			h[f] = r.next()
		}
		for s := 0; s < S; s++ {
			d := 0.0
			for f := 0; f < F; f++ {
				d += h[f] * x[s*F+f]
			}
			if d >= 0 {
				y[k*S+s] = 1
			} else {
				y[k*S+s] = -1
			}
		}
	}
	return
}

type result struct {
	k, mistakes int
	sum         float64
}

func train(k int, x, y []float64) result {
	w := make([]float64, F)
	b := 0.0
	mistakes := 0
	for e := 0; e < E; e++ {
		mistakes = 0
		for s := 0; s < S; s++ {
			row := x[s*F : s*F+F]
			d := b
			for f := 0; f < F; f++ {
				d += w[f] * row[f]
			}
			t := y[k*S+s]
			if d*t <= 0 {
				mistakes++
				for f := 0; f < F; f++ {
					w[f] += t * row[f]
				}
				b += t
			}
		}
	}
	sum := b
	for f := 0; f < F; f++ {
		sum += w[f]
	}
	return result{k, mistakes, sum}
}

func trial(x, y []float64, linear bool, null *bufio.Writer) time.Duration {
	t0 := time.Now()
	res := make([]result, K)
	if linear {
		for k := 0; k < K; k++ {
			res[k] = train(k, x, y)
		}
	} else {
		out := make(chan result)
		for k := 0; k < K; k++ {
			go func(k int) { out <- train(k, x, y) }(k)
		}
		for i := 0; i < K; i++ {
			r := <-out
			res[r.k] = r
		}
	}
	for _, r := range res {
		fmt.Fprintf(null, "%d %d %.9f\n", r.k, r.mistakes, r.sum)
	}
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
	x, y := makeData()
	for t := 0; t < trials; t++ {
		fmt.Printf("%.1f\n", float64(trial(x, y, linear, null).Nanoseconds())/1000)
	}
}
