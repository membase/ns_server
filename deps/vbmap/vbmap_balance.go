package main

import (
	"bytes"
	"fmt"
	"math/rand"
)

// Matrix R with some meta-information.
type R struct {
	Matrix  [][]int // actual matrix
	RowSums []int   // row sums for the matrix
	ColSums []int   // column sums for the matrix

	params           VbmapParams // corresponding vbucket map params
	expectedColSum   int         // expected column sum
	expectedOutliers int         // number of columns that can be off-by-one

	outliers int // actual number of columns that are off-by-one

	// sum of absolute differences between column sum and expected column
	// sum; it's called 'raw' because it doesn't take into consideration
	// that expectedOutliers number of columns can be off-by-one; the
	// smaller the better
	rawEvaluation int
}

func (cand R) String() string {
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

	for i, row := range cand.Matrix {
		fmt.Fprintf(buffer, "%3d |", cand.params.Tags[Node(i)])
		for _, elem := range row {
			fmt.Fprintf(buffer, "%3d ", elem)
		}
		fmt.Fprintf(buffer, "| %d\n", cand.RowSums[i])
	}

	fmt.Fprintf(buffer, "____|")
	for _ = range nodes {
		fmt.Fprintf(buffer, "____")
	}
	fmt.Fprintf(buffer, "|\n")

	fmt.Fprintf(buffer, "    |")
	for i := range nodes {
		fmt.Fprintf(buffer, "%3d ", cand.ColSums[i])
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
// Uses buildInitialR to construct R.
func makeR(params VbmapParams, RI RI) (result R) {
	result.params = params
	result.Matrix = buildInitialR(params, RI)
	result.ColSums = make([]int, params.NumNodes)
	result.RowSums = make([]int, params.NumNodes)

	for i, row := range result.Matrix {
		rowSum := 0
		for j, elem := range row {
			rowSum += elem
			result.ColSums[j] += elem
		}
		result.RowSums[i] = rowSum
	}

	numReplications := params.NumVBuckets * params.NumReplicas
	result.expectedColSum = numReplications / params.NumNodes
	result.expectedOutliers = numReplications % params.NumNodes

	for _, sum := range result.ColSums {
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
func (cand R) computeEvaluation(rawEval int, outliers int) (eval int) {
	eval = rawEval
	if outliers > cand.expectedOutliers {
		eval -= cand.expectedOutliers
	} else {
		eval -= outliers
	}

	return
}

// Compute adjusted evaluation of matrix R.
func (cand R) evaluation() int {
	return cand.computeEvaluation(cand.rawEvaluation, cand.outliers)
}

// Compute a change in number of outlying elements after swapping elements j
// and k in certain row.
func (cand R) swapOutliersChange(row int, j int, k int) (change int) {
	a, b := cand.Matrix[row][j], cand.Matrix[row][k]
	ca := cand.ColSums[j] - a + b
	cb := cand.ColSums[k] - b + a

	if cand.ColSums[j] == cand.expectedColSum+1 {
		change -= 1
	}
	if cand.ColSums[k] == cand.expectedColSum+1 {
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
func (cand R) swapRawEvaluationChange(row int, j int, k int) (change int) {
	a, b := cand.Matrix[row][j], cand.Matrix[row][k]
	ca := cand.ColSums[j] - a + b
	cb := cand.ColSums[k] - b + a

	evalA := Abs(ca - cand.expectedColSum)
	evalB := Abs(cb - cand.expectedColSum)

	oldEvalA := Abs(cand.ColSums[j] - cand.expectedColSum)
	oldEvalB := Abs(cand.ColSums[k] - cand.expectedColSum)

	change = evalA - oldEvalA + evalB - oldEvalB

	return
}

// Compute a potential change in evaluation after swapping element j and k in
// certain row.
func (cand R) swapBenefit(row int, j int, k int) int {
	eval := cand.evaluation()

	swapOutliers := cand.outliers + cand.swapOutliersChange(row, j, k)
	swapRawEval := cand.rawEvaluation + cand.swapRawEvaluationChange(row, j, k)
	swapEval := cand.computeEvaluation(swapRawEval, swapOutliers)

	return swapEval - eval
}

// Swap element j and k in a certain row.
func (cand *R) swapElems(row int, j int, k int) {
	if cand.Matrix[row][j] == 0 || cand.Matrix[row][k] == 0 {
		panic(fmt.Sprintf("swapping one or more zeros (%d: %d <-> %d)",
			row, j, k))
	}

	cand.rawEvaluation += cand.swapRawEvaluationChange(row, j, k)
	cand.outliers += cand.swapOutliersChange(row, j, k)

	a, b := cand.Matrix[row][j], cand.Matrix[row][k]

	cand.ColSums[j] += b - a
	cand.ColSums[k] += a - b
	cand.Matrix[row][j], cand.Matrix[row][k] = b, a
}

// Make a copy of R.
func (cand R) copy() (result R) {
	result.params = cand.params
	result.expectedColSum = cand.expectedColSum
	result.expectedOutliers = cand.expectedOutliers
	result.outliers = cand.outliers
	result.rawEvaluation = cand.rawEvaluation

	result.Matrix = make([][]int, cand.params.NumNodes)
	for i, row := range cand.Matrix {
		result.Matrix[i] = make([]int, cand.params.NumNodes)
		copy(result.Matrix[i], row)
	}

	result.RowSums = make([]int, cand.params.NumNodes)
	copy(result.RowSums, cand.RowSums)

	result.ColSums = make([]int, cand.params.NumNodes)
	copy(result.ColSums, cand.ColSums)

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
func doBuildR(params VbmapParams, RI RI) (best R) {
	cand := makeR(params, RI)
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

		for i, elem := range cand.ColSums {
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
			lowElem := cand.Matrix[row][lowIx]
			highElem := cand.Matrix[row][highIx]

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
func BuildR(params VbmapParams, RI RI) (best R) {
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
