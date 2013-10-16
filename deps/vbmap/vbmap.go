package main

import (
	"bytes"
	"container/heap"
	"errors"
	"fmt"
	"math/rand"
	"sort"
)

type Node int
type Tag uint
type TagMap map[Node]Tag

var (
	ErrorNoSolution = errors.New("The problem has no solution")
)

type VbmapParams struct {
	Tags TagMap

	NumNodes    int
	NumSlaves   int
	NumVBuckets int
	NumReplicas int
}

func (params VbmapParams) Nodes() (nodes []Node) {
	for n := 0; n < params.NumNodes; n++ {
		nodes = append(nodes, Node(n))
	}

	return
}

func (params VbmapParams) String() string {
	return fmt.Sprintf("VbmapParams{Tags: %s, NumNodes: %d, "+
		"NumSlaves: %d, NumVBuckets: %d, NumReplicas: %d",
		params.Tags, params.NumNodes, params.NumSlaves,
		params.NumVBuckets, params.NumReplicas)
}

func (tags TagMap) String() string {
	return fmt.Sprintf("%v", map[Node]Tag(tags))
}

func (tags TagMap) TagsList() (result []Tag) {
	seen := make(map[Tag]bool)

	for _, t := range tags {
		if _, present := seen[t]; !present {
			result = append(result, t)
			seen[t] = true
		}
	}

	return
}

func (tags TagMap) TagsCount() int {
	return len(tags.TagsList())
}

func (tags TagMap) TagsNodesMap() (m map[Tag][]Node) {
	m = make(map[Tag][]Node)
	for _, tag := range tags.TagsList() {
		m[tag] = nil
	}

	for node, tag := range tags {
		m[tag] = append(m[tag], node)
	}

	return
}

type RI [][]bool

type RIGenerator interface {
	SetParams(params map[string]string) error
	Generate(params VbmapParams) (RI, error)
	fmt.Stringer
}

type DontAcceptRIGeneratorParams struct{}

func (_ DontAcceptRIGeneratorParams) SetParams(params map[string]string) error {
	for k, _ := range params {
		return fmt.Errorf("unsupported parameter '%s'", k)
	}

	return nil
}

func (RI RI) String() string {
	buffer := &bytes.Buffer{}

	for _, row := range RI {
		for _, elem := range row {
			fmt.Fprintf(buffer, "%2d ", b2i(elem))
		}
		fmt.Fprintf(buffer, "\n")
	}

	return buffer.String()
}

// Matrix R with some meta-information.
type RCandidate struct {
	params VbmapParams // corresponding vbucket map params
	matrix [][]int     // actual matrix

	rowSums          []int // row sums for the matrix
	colSums          []int // column sums for the matrix
	expectedColSum   int   // expected column sum
	expectedOutliers int   // number of columns that can be off-by-one

	outliers int // actual number of columns that are off-by-one

	// sum of absolute differences between column sum and expected column
	// sum; it's called 'raw' because it doesn't take into consideration
	// that expectedOutliers number of columns can be off-by-one; the
	// smaller the better
	rawEvaluation int
}

func (cand RCandidate) String() string {
	buffer := &bytes.Buffer{}

	nodes := cand.params.Nodes()

	fmt.Fprintf(buffer, "    |")
	for _, node := range nodes {
		fmt.Fprintf(buffer, "%3d ", cand.params.Tags[node])
	}
	fmt.Fprintf(buffer, "|\n")

	fmt.Fprintf(buffer, "----|")
	for _ = range nodes {
		fmt.Fprintf(buffer, "----")
	}
	fmt.Fprintf(buffer, "|\n")

	for i, row := range cand.matrix {
		fmt.Fprintf(buffer, "%3d |", cand.params.Tags[Node(i)])
		for _, elem := range row {
			fmt.Fprintf(buffer, "%3d ", elem)
		}
		fmt.Fprintf(buffer, "| %d\n", cand.rowSums[i])
	}

	fmt.Fprintf(buffer, "____|")
	for _ = range nodes {
		fmt.Fprintf(buffer, "____")
	}
	fmt.Fprintf(buffer, "|\n")

	fmt.Fprintf(buffer, "    |")
	for i := range nodes {
		fmt.Fprintf(buffer, "%3d ", cand.colSums[i])
	}
	fmt.Fprintf(buffer, "|\n")
	fmt.Fprintf(buffer, "Evaluation: %d\n", cand.evaluation())

	return buffer.String()
}

// Build initial matrix R from RI.
//
// It just spreads active vbuckets uniformly between the nodes. And then for
// each node spreads replica vbuckets among the slaves of this node.
func buildInitialR(params VbmapParams, RI RI) (R [][]int) {
	activeVbsPerNode := SpreadSum(params.NumVBuckets, params.NumNodes)

	R = make([][]int, len(RI))
	if params.NumSlaves == 0 {
		return
	}

	for i, row := range RI {
		rowSum := activeVbsPerNode[i] * params.NumReplicas
		slaveVbs := SpreadSum(rowSum, params.NumSlaves)

		R[i] = make([]int, len(row))

		slave := 0
		for j, elem := range row {
			if elem {
				R[i][j] = slaveVbs[slave]
				slave += 1
			}
		}
	}

	return
}

// Construct initial matrix R from RI.
//
// Uses buildInitialR to construct RCandidate.
func makeRCandidate(params VbmapParams, RI RI) (result RCandidate) {
	result.params = params
	result.matrix = buildInitialR(params, RI)
	result.colSums = make([]int, params.NumNodes)
	result.rowSums = make([]int, params.NumNodes)

	for i, row := range result.matrix {
		rowSum := 0
		for j, elem := range row {
			rowSum += elem
			result.colSums[j] += elem
		}
		result.rowSums[i] = rowSum
	}

	numReplications := params.NumVBuckets * params.NumReplicas
	result.expectedColSum = numReplications / params.NumNodes
	result.expectedOutliers = numReplications % params.NumNodes

	for _, sum := range result.colSums {
		result.rawEvaluation += Abs(sum - result.expectedColSum)
		if sum == result.expectedColSum+1 {
			result.outliers += 1
		}
	}

	return
}

// Compute adjusted evaluation of matrix R from raw evaluation and number of
// outliers.
//
// It differs from raw evaluation in that it allows fixed number of column
// sums to be off-by-one.
func (cand RCandidate) computeEvaluation(rawEval int, outliers int) (eval int) {
	eval = rawEval
	if outliers > cand.expectedOutliers {
		eval -= cand.expectedOutliers
	} else {
		eval -= outliers
	}

	return
}

// Compute adjusted evaluation of matrix R.
func (cand RCandidate) evaluation() int {
	return cand.computeEvaluation(cand.rawEvaluation, cand.outliers)
}

// Compute a change in number of outlying elements after swapping elements j
// and k in certain row.
func (cand RCandidate) swapOutliersChange(row int, j int, k int) (change int) {
	a, b := cand.matrix[row][j], cand.matrix[row][k]
	ca := cand.colSums[j] - a + b
	cb := cand.colSums[k] - b + a

	if cand.colSums[j] == cand.expectedColSum+1 {
		change -= 1
	}
	if cand.colSums[k] == cand.expectedColSum+1 {
		change -= 1
	}
	if ca == cand.expectedColSum+1 {
		change += 1
	}
	if cb == cand.expectedColSum+1 {
		change += 1
	}

	return
}

// Compute a change in rawEvaluation after swapping elements j and k in
// certain row.
func (cand RCandidate) swapRawEvaluationChange(row int, j int, k int) (change int) {
	a, b := cand.matrix[row][j], cand.matrix[row][k]
	ca := cand.colSums[j] - a + b
	cb := cand.colSums[k] - b + a

	evalA := Abs(ca - cand.expectedColSum)
	evalB := Abs(cb - cand.expectedColSum)

	oldEvalA := Abs(cand.colSums[j] - cand.expectedColSum)
	oldEvalB := Abs(cand.colSums[k] - cand.expectedColSum)

	change = evalA - oldEvalA + evalB - oldEvalB

	return
}

// Compute a potential change in evaluation after swapping element j and k in
// certain row.
func (cand RCandidate) swapBenefit(row int, j int, k int) int {
	eval := cand.evaluation()

	swapOutliers := cand.outliers + cand.swapOutliersChange(row, j, k)
	swapRawEval := cand.rawEvaluation + cand.swapRawEvaluationChange(row, j, k)
	swapEval := cand.computeEvaluation(swapRawEval, swapOutliers)

	return swapEval - eval
}

// Swap element j and k in a certain row.
func (cand *RCandidate) swapElems(row int, j int, k int) {
	if cand.matrix[row][j] == 0 || cand.matrix[row][k] == 0 {
		panic(fmt.Sprintf("swapping one or more zeros (%d: %d <-> %d)",
			row, j, k))
	}

	cand.rawEvaluation += cand.swapRawEvaluationChange(row, j, k)
	cand.outliers += cand.swapOutliersChange(row, j, k)

	a, b := cand.matrix[row][j], cand.matrix[row][k]

	cand.colSums[j] += b - a
	cand.colSums[k] += a - b
	cand.matrix[row][j], cand.matrix[row][k] = b, a
}

// Make a copy of RCandidate.
func (cand RCandidate) copy() (result RCandidate) {
	result.params = cand.params
	result.expectedColSum = cand.expectedColSum
	result.expectedOutliers = cand.expectedOutliers
	result.outliers = cand.outliers
	result.rawEvaluation = cand.rawEvaluation

	result.matrix = make([][]int, cand.params.NumNodes)
	for i, row := range cand.matrix {
		result.matrix[i] = make([]int, cand.params.NumNodes)
		copy(result.matrix[i], row)
	}

	result.rowSums = make([]int, cand.params.NumNodes)
	copy(result.rowSums, cand.rowSums)

	result.colSums = make([]int, cand.params.NumNodes)
	copy(result.colSums, cand.colSums)

	return
}

// A pair of elements (j and k) in a row that were swapped recently and so
// should not be swapped again.
type TabuPair struct {
	row, j, k int
}

// A single element from a TabuPair.
type TabuElem struct {
	row, col int
}

// A store of element pairs that were swapped recently.
type Tabu struct {
	tabu map[TabuPair]int // pairs that were swapped recently

	// index from elements to pair they're part of; this is needed to be
	// able to remove a pair from tabu if one of its elements gets swapped
	// with some other element;
	elemIndex map[TabuElem]TabuPair

	// index from iteration number to a pair that was tabu-ed on that
	// iteration; used to expire pairs that spent too much time in a tabu;
	expireIndex map[int]TabuPair
}

func makeTabuPair(row int, j int, k int) TabuPair {
	if j > k {
		j, k = k, j
	}
	return TabuPair{row, j, k}
}

func makeTabu() Tabu {
	return Tabu{make(map[TabuPair]int),
		make(map[TabuElem]TabuPair),
		make(map[int]TabuPair)}
}

// Add a pair to a tabu. And remove any pairs that have elements in common
// with this pair.
func (tabu Tabu) add(time int, row int, j int, k int) {
	oldItem, present := tabu.elemIndex[TabuElem{row, j}]
	if present {
		tabu.expire(tabu.tabu[oldItem])
	}

	oldItem, present = tabu.elemIndex[TabuElem{row, k}]
	if present {
		tabu.expire(tabu.tabu[oldItem])
	}

	item := makeTabuPair(row, j, k)
	tabu.tabu[item] = time
	tabu.expireIndex[time] = item

	tabu.elemIndex[TabuElem{row, j}] = item
	tabu.elemIndex[TabuElem{row, k}] = item
}

// Check if a pair of elements is tabu-ed.
func (tabu Tabu) member(row int, j int, k int) bool {
	_, present := tabu.tabu[makeTabuPair(row, j, k)]
	return present
}

// Expire tabu pair that was added at certain iteration.
func (tabu Tabu) expire(time int) {
	item := tabu.expireIndex[time]
	delete(tabu.expireIndex, time)
	delete(tabu.tabu, item)
	delete(tabu.elemIndex, TabuElem{item.row, item.j})
	delete(tabu.elemIndex, TabuElem{item.row, item.k})
}

// Try to build balanced matrix R base on matrix RI.
//
// General approach is as follows. Fixed number of attempts is made to improve
// matrix evaluation by swapping two elements in some row. Candidates for
// swapping are selected to improve or at least not make worse the
// evaluation. But occasionally swaps that make evaluation worse are also
// allowed. After swapping the elements, corresponding pair is put into a tabu
// store to ensure that this improvement is not undone too soon. But after
// sufficient number of iterations, items in a tabu store are expired. If some
// item stays in the tabu for a long time, it might mean that the search is
// stuck at some local minimum. So allowing for some improvements to be undone
// might help to get out of it. Finally, if there's been no improvement in
// evaluation for quite a long time, then the search is stopped. It might be
// retried by buildR(). This will start everything over with new initial
// matrix R.
func doBuildR(params VbmapParams, RI RI) (best RCandidate) {
	cand := makeRCandidate(params, RI)
	best = cand.copy()

	if params.NumSlaves <= 1 || params.NumReplicas == 0 {
		// nothing to optimize here; just return
		return
	}

	attempts := 10 * params.NumNodes * params.NumNodes
	expire := 10 * params.NumNodes
	noImprovementLimit := params.NumNodes * params.NumNodes

	highElems := make([]int, params.NumNodes)
	lowElems := make([]int, params.NumNodes)

	candidateRows := make([]int, params.NumNodes)
	tabu := makeTabu()

	noCandidate := 0
	swapTabued := 0
	swapDecreased := 0
	swapIndifferent := 0
	swapIncreased := 0

	t := 0
	noImprovementIters := 0

	for t = 0; t < attempts; t++ {
		if t >= expire {
			tabu.expire(t - expire)
		}

		if noImprovementIters >= noImprovementLimit {
			break
		}

		noImprovementIters++

		if best.evaluation() == 0 {
			break
		}

		// indexes of columns that have sums higher than expected
		highElems = []int{}
		// indexes of columns that have sums lower or equal to expected
		lowElems = []int{}

		for i, elem := range cand.colSums {
			switch {
			case elem <= cand.expectedColSum:
				lowElems = append(lowElems, i)
			case elem > cand.expectedColSum:
				highElems = append(highElems, i)
			}
		}

		// indexes of columns that we're planning to adjust
		lowIx := lowElems[rand.Intn(len(lowElems))]
		highIx := highElems[rand.Intn(len(highElems))]

		// indexes of rows where the elements in lowIx and highIx
		// columns can be swapped with some benefit
		candidateRows = []int{}

		for row := 0; row < params.NumNodes; row++ {
			lowElem := cand.matrix[row][lowIx]
			highElem := cand.matrix[row][highIx]

			if lowElem != 0 && highElem != 0 && highElem != lowElem {
				benefit := cand.swapBenefit(row, lowIx, highIx)

				if benefit >= 0 && rand.Intn(20) != 0 {
					continue
				}

				candidateRows = append(candidateRows, row)
			}
		}

		if len(candidateRows) == 0 {
			noCandidate++
			continue
		}

		row := candidateRows[rand.Intn(len(candidateRows))]

		if tabu.member(row, lowIx, highIx) {
			swapTabued++
			continue
		}

		old := cand.evaluation()

		cand.swapElems(row, lowIx, highIx)
		tabu.add(t, row, lowIx, highIx)

		if old == cand.evaluation() {
			swapIndifferent++
		} else if old < cand.evaluation() {
			swapIncreased++
		} else {
			swapDecreased++
		}

		if cand.evaluation() < best.evaluation() {
			best = cand.copy()
			noImprovementIters = 0
		}
	}

	diag.Printf("Search stats")
	diag.Printf("  iters -> %d", t)
	diag.Printf("  no improvement termination? -> %v",
		noImprovementIters >= noImprovementLimit)
	diag.Printf("  noCandidate -> %d", noCandidate)
	diag.Printf("  swapTabued -> %d", swapTabued)
	diag.Printf("  swapDecreased -> %d", swapDecreased)
	diag.Printf("  swapIndifferent -> %d", swapIndifferent)
	diag.Printf("  swapIncreased -> %d", swapIncreased)
	diag.Printf("")

	return
}

// Build balanced matrix R from RI.
//
// Main job is done in doBuildR(). It can be called several times if resulting
// matrix evaluation is not zero. Each time doBuildR() starts from new
// randomized initial R. If this doesn't lead to a matrix with zero evaluation
// after fixed number of iterations, then the matrix which had the best
// evaluation is returned.
func buildR(params VbmapParams, RI RI) (best RCandidate) {
	bestEvaluation := (1 << 31) - 1

	for i := 0; i < 10; i++ {
		R := doBuildR(params, RI)
		if R.evaluation() < bestEvaluation {
			best = R
			bestEvaluation = R.evaluation()
		}

		if bestEvaluation == 0 {
			diag.Printf("Found balanced map R after %d attempts", i)
			break
		}
	}

	if bestEvaluation != 0 {
		diag.Printf("Failed to find balanced map R (best evaluation %d)",
			bestEvaluation)
	}

	return
}

type Vbmap [][]Node

func (vbmap Vbmap) String() string {
	buffer := &bytes.Buffer{}

	for i, nodes := range vbmap {
		fmt.Fprintf(buffer, "%4d: ", i)
		for _, n := range nodes {
			fmt.Fprintf(buffer, "%3d ", n)
		}
		fmt.Fprintf(buffer, "\n")
	}

	return buffer.String()
}

func makeVbmap(params VbmapParams) (vbmap Vbmap) {
	vbmap = make([][]Node, params.NumVBuckets)
	for v := 0; v < params.NumVBuckets; v++ {
		vbmap[v] = make([]Node, params.NumReplicas+1)
	}

	return
}

// Represents a slave node.
type Slave struct {
	index   int // column index of this slave in corresponding row of R
	count   int // number of vbuckets that can be put on this slave
	numUsed int // number of times this slave was used so far
}

// A heap of slaves of some node. Slaves in the heap are ordered in the
// descending order of number of vbuckets slots left on these slaves. If for
// some pair of nodes number of vbuckets left is identical, then the node that
// has been used less is preferred.
type SlaveHeap []Slave

func makeSlave(index int, count int, params VbmapParams) (slave Slave) {
	slave.index = index
	slave.count = count
	return
}

func (h SlaveHeap) Len() int {
	return len(h)
}

func (h SlaveHeap) Less(i, j int) (result bool) {
	switch {
	case h[i].count > h[j].count:
		result = true
	case h[i].count == h[j].count:
		result = h[i].numUsed < h[j].numUsed
	default:
		result = false
	}

	return
}

func (h SlaveHeap) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
}

func (h *SlaveHeap) Push(x interface{}) {
	*h = append(*h, x.(Slave))
}

func (h *SlaveHeap) Pop() interface{} {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[0 : n-1]
	return x
}

// A pair of column indexes of two elements in the same row of matrix R. Used
// to track how many times certain pair of nodes is used adjacently to
// replicate some active vbucket from a certain node.
type IndexPair struct {
	x, y int
}

// Get current usage count for slaves x and y.
func getCount(counts map[IndexPair]int, x int, y int) (count int) {
	count, present := counts[IndexPair{x, y}]
	if !present {
		count = 0
	}

	return
}

// Increment usage count for slave x and y.
func incCount(counts map[IndexPair]int, x int, y int) {
	count := getCount(counts, x, y)
	counts[IndexPair{x, y}] = count + 1
}

// Choose numReplicas replicas out of candidates array based on counts.
//
// It does so by prefering a replica r with the lowest count for pair {prev,
// r} in counts. prev is either -1 (which means master node) or replica from
// previous turn. If for several possible replicas counts are the same then
// one of them is selected uniformly.
func chooseReplicas(candidates []Slave,
	numReplicas int, counts map[IndexPair]int) (result []Slave, intact []Slave) {

	result = make([]Slave, numReplicas)
	resultIxs := make([]int, numReplicas)
	intact = make([]Slave, len(candidates)-numReplicas)[:0]

	candidatesMap := make(map[int]Slave)
	available := make(map[int]bool)

	for _, r := range candidates {
		candidatesMap[r.index] = r
		available[r.index] = true
	}

	for i := 0; i < numReplicas; i++ {
		var possibleReplicas []int = nil
		var cost int

		processPair := func(x, y int) {
			if x == y {
				return
			}

			cand := y
			candCost := getCount(counts, x, y)

			if possibleReplicas == nil {
				cost = candCost
			}

			if candCost < cost {
				possibleReplicas = append([]int(nil), cand)
				cost = candCost
			} else if candCost == cost {
				possibleReplicas = append(possibleReplicas, cand)
			}
		}

		var prev int
		if i == 0 {
			// master
			prev = -1
		} else {
			prev = resultIxs[i-1]
		}

		for x, _ := range available {
			processPair(prev, x)
		}

		if possibleReplicas == nil {
			panic("couldn't find a replica")
		}

		sort.Ints(possibleReplicas)
		replica := possibleReplicas[rand.Intn(len(possibleReplicas))]

		resultIxs[i] = replica
		delete(available, replica)
	}

	for i, r := range resultIxs {
		result[i] = candidatesMap[r]
	}

	for s, _ := range available {
		intact = append(intact, candidatesMap[s])
	}

	return
}

// Construct vbucket map from a matrix R.
func buildVbmap(R RCandidate) (vbmap Vbmap) {
	params := R.params
	vbmap = makeVbmap(params)

	// determines how many active vbuckets each node has
	var nodeVbs []int
	if params.NumReplicas == 0 || params.NumSlaves == 0 {
		// If there's only one copy of every vbucket, then matrix R is
		// just a null matrix. So we just spread the vbuckets evenly
		// among the nodes and we're almost done.
		nodeVbs = SpreadSum(params.NumVBuckets, params.NumNodes)
	} else {
		// Otherwise matrix R defines the amount of active vbuckets
		// each node has.
		nodeVbs = make([]int, params.NumNodes)
		for i, sum := range R.rowSums {
			vbs := sum / params.NumReplicas
			if sum%params.NumReplicas != 0 {
				panic("row sum is not multiple of NumReplicas")
			}

			nodeVbs[i] = vbs
		}
	}

	vbucket := 0
	for i, row := range R.matrix {
		slaves := &SlaveHeap{}
		counts := make(map[IndexPair]int)

		heap.Init(slaves)

		vbs := nodeVbs[i]

		for s, count := range row {
			if count != 0 {
				heap.Push(slaves, makeSlave(s, count, params))
			}
		}

		if slaves.Len() == 0 {
			// Row matrix contained only zeros. This usually means
			// that replica count is zero. Other possibility is
			// that the number of vbucket is less than number of
			// nodes and some of the nodes end up with no vbuckets
			// at all. In any case, we just mark the node as a
			// master for its vbuckets (if any).

			for vbs > 0 {
				vbmap[vbucket][0] = Node(i)
				vbs--
				vbucket++
			}

			continue
		}

		// We're selecting possible candidates for this particular
		// replica chain. To ensure that we don't end up in a
		// situation when there's only one slave left in the heap and
		// it's count is greater than one, we always pop slaves with
		// maximum count of vbuckets left first (see SlaveHeap.Less()
		// method for details). When counts are the same, node that
		// has been used less is preferred. We try to select more
		// candidates than the number of replicas we need. This is to
		// have more freedom when selecting actual replicas. For
		// details on this look at chooseReplicas() function.
		candidates := make([]Slave, params.NumSlaves)
		for vbs > 0 {
			candidates = nil
			vbmap[vbucket][0] = Node(i)

			var lastCount int
			var different bool = false

			for r := 0; r < params.NumReplicas; r++ {
				if slaves.Len() == 0 {
					panic("Ran out of slaves")
				}

				slave := heap.Pop(slaves).(Slave)
				candidates = append(candidates, slave)

				if r > 0 {
					different = different || (slave.count != lastCount)
				}

				lastCount = slave.count
			}

			// If candidates that we selected so far have
			// different counts, to simplify chooseReplicas()
			// logic we don't try select other candidates. This is
			// needed because all the candidates with higher
			// counts has to be selected by
			// chooseReplicas(). Otherwise it would be possible to
			// end up with a single slave with count greater than
			// one in the heap.
			if !different {
				for {
					if slaves.Len() == 0 {
						break
					}

					// We add more slaves to the candidate
					// list while all of them has the same
					// count of vbuckets left.
					slave := heap.Pop(slaves).(Slave)
					if slave.count == lastCount {
						candidates = append(candidates, slave)
					} else {
						heap.Push(slaves, slave)
						break
					}
				}
			}

			// Here we just choose actual replicas for this
			// vbucket out of candidates. We adjust usage stats
			// for chosen slaves. And push them back to the heap
			// if their vbuckets left count is non-zero.
			replicas, intact := chooseReplicas(candidates, params.NumReplicas, counts)

			for turn, slave := range replicas {
				slave.count--
				slave.numUsed++

				vbmap[vbucket][turn+1] = Node(slave.index)

				if slave.count != 0 {
					heap.Push(slaves, slave)
				}

				var prev int
				if turn == 0 {
					// this means master
					prev = -1
				} else {
					prev = replicas[turn-1].index
				}

				incCount(counts, prev, slave.index)
			}

			// just push all the unused slaves back to the heap
			for _, slave := range intact {
				heap.Push(slaves, slave)
			}

			vbs--
			vbucket++
		}
	}

	return
}

// Generate vbucket map given a generator for matrix RI and vbucket map
// parameters.
func VbmapGenerate(params VbmapParams, gen RIGenerator) (vbmap Vbmap, err error) {
	RI, err := gen.Generate(params)
	if err != nil {
		return
	}

	diag.Printf("Generated topology:\n%s", RI.String())

	R := buildR(params, RI)

	diag.Printf("Final map R:\n%s", R.String())

	return buildVbmap(R), nil
}
