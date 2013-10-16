package main

import (
	"log"
	"math/rand"
	"reflect"
	"testing"
	"testing/quick"
	"time"
)

type TestingWriter struct {
	t *testing.T
}

var allGenerators []RIGenerator = []RIGenerator{
	makeDummyRIGenerator(),
	makeMaxFlowRIGenerator(),
}

var tagAwareGenerators []RIGenerator = []RIGenerator{
	makeMaxFlowRIGenerator(),
}

func (w TestingWriter) Write(p []byte) (n int, err error) {
	w.t.Logf("%s", string(p))
	return len(p), nil
}

func setup(t *testing.T) {
	diag = log.New(TestingWriter{t}, "", 0)
}

func trivialTags(nodes int) (tags map[Node]Tag) {
	tags = make(map[Node]Tag)
	for n := 0; n < nodes; n++ {
		tags[Node(n)] = Tag(n)
	}

	return
}

func TestRReplicaBalance(t *testing.T) {
	seed = time.Now().UTC().UnixNano()
	t.Logf("Using seed %d", seed)
	rand.Seed(seed)

	setup(t)

	for nodes := 1; nodes <= 50; nodes++ {
		tags := trivialTags(nodes)

		for replicas := 1; replicas <= 3; replicas++ {
			t.Log("=======================================")
			t.Logf("Generating R for %d node, %d replicas",
				nodes, replicas)

			params = VbmapParams{
				Tags:        tags,
				NumNodes:    nodes,
				NumSlaves:   10,
				NumVBuckets: 1024,
				NumReplicas: replicas,
			}

			normalizeParams(&params)

			for _, gen := range allGenerators {
				RI, err := gen.Generate(params)
				if err != nil {
					t.Errorf("Couldn't generate RI: %s", err.Error())
				}

				R := buildR(params, RI)
				if R.evaluation() != 0 {
					t.Error("Generated map R has non-zero evaluation")
				}
			}
		}
	}
}

func (_ VbmapParams) Generate(rand *rand.Rand, size int) reflect.Value {
	nodes := rand.Int()%100 + 1
	replicas := rand.Int() % 4

	params = VbmapParams{
		Tags:        trivialTags(nodes),
		NumNodes:    nodes,
		NumSlaves:   10,
		NumVBuckets: 1024,
		NumReplicas: replicas,
	}
	normalizeParams(&params)

	return reflect.ValueOf(params)
}

func checkRIProperties(gen RIGenerator, params VbmapParams) bool {
	RI, err := gen.Generate(params)
	if err != nil {
		return false
	}

	if len(RI) != params.NumNodes {
		return false
	}

	if len(RI[0]) != params.NumNodes {
		return false
	}

	colSums := make([]int, params.NumNodes)
	rowSums := make([]int, params.NumNodes)

	b2i := map[bool]int{false: 0, true: 1}
	for i, row := range RI {
		for j, elem := range row {
			colSums[j] += b2i[elem]
			rowSums[i] += b2i[elem]
		}
	}

	for i := range colSums {
		if colSums[i] != params.NumSlaves {
			return false
		}

		if rowSums[i] != params.NumSlaves {
			return false
		}
	}

	return true
}

func TestRIProperties(t *testing.T) {
	setup(t)

	for _, gen := range allGenerators {
		check := func(params VbmapParams) bool {
			return checkRIProperties(gen, params)
		}

		err := quick.Check(check, &quick.Config{MaxCount: 100})
		if err != nil {
			t.Error(err)
		}
	}
}

func checkRProperties(gen RIGenerator, params VbmapParams, seed int64) bool {
	rand.Seed(seed)

	RI, err := gen.Generate(params)
	if err != nil {
		return false
	}

	R := buildR(params, RI)
	if params.NumReplicas == 0 {
		// no replicas? R should obviously be empty
		for _, row := range R.matrix {
			for _, elem := range row {
				if elem != 0 {
					return false
				}
			}
		}
	} else {
		// check that we follow RI topology
		for i, row := range RI {
			for j, elem := range row {
				if !elem && R.matrix[i][j] != 0 ||
					elem && R.matrix[i][j] == 0 {
					return false
				}
			}
		}

		totalVBuckets := 0

		// check active vbuckets balance
		for _, sum := range R.rowSums {
			if sum%params.NumReplicas != 0 {
				return false
			}

			vbuckets := sum / params.NumReplicas
			expected := params.NumVBuckets / params.NumNodes

			if vbuckets != expected && vbuckets != expected+1 {
				return false
			}

			totalVBuckets += vbuckets
		}

		if totalVBuckets != params.NumVBuckets {
			return false
		}
	}

	return true
}

func TestRProperties(t *testing.T) {
	setup(t)

	for _, gen := range allGenerators {

		check := func(params VbmapParams, seed int64) bool {
			return checkRProperties(gen, params, seed)
		}

		err := quick.Check(check, &quick.Config{MaxCount: 100})
		if err != nil {
			t.Error(err)
		}
	}
}

type NodePair struct {
	x, y Node
}

func checkVbmapProperties(gen RIGenerator, params VbmapParams, seed int64) bool {
	rand.Seed(seed)

	RI, err := gen.Generate(params)
	if err != nil {
		return false
	}

	R := buildR(params, RI)
	vbmap := buildVbmap(R)

	if len(vbmap) != params.NumVBuckets {
		return false
	}

	activeVBuckets := make([]int, params.NumNodes)
	replicaVBuckets := make([]int, params.NumNodes)

	replications := make(map[NodePair]int)

	for _, chain := range vbmap {
		if len(chain) != params.NumReplicas+1 {
			return false
		}

		master := chain[0]
		activeVBuckets[int(master)] += 1

		for _, replica := range chain[1:] {
			// all the replications correspond to ones
			// defined by R
			if !RI[int(master)][int(replica)] {
				return false
			}

			replicaVBuckets[int(replica)] += 1

			pair := NodePair{master, replica}
			if _, present := replications[pair]; !present {
				replications[pair] = 0
			}

			replications[pair] += 1
		}
	}

	// number of replications should correspond to one defined by R
	for i, row := range R.matrix {
		for j, elem := range row {
			if elem != 0 {
				pair := NodePair{Node(i), Node(j)}

				count, present := replications[pair]
				if !present || count != elem {
					return false
				}
			}
		}
	}

	// number of active vbuckets should correspond to one defined
	// by matrix R
	for n, sum := range R.rowSums {
		if params.NumReplicas != 0 {
			// if we have at least one replica then number
			// of active vbuckets is defined by matrix R
			if sum/params.NumReplicas != activeVBuckets[n] {
				return false
			}
		} else {
			// otherwise matrix R is empty and we just
			// need to check that active vbuckets are
			// distributed evenly
			expected := params.NumVBuckets / params.NumNodes
			if activeVBuckets[n] != expected &&
				activeVBuckets[n] != expected+1 {
				return false
			}
		}
	}

	// number of replica vbuckets should correspond to one defined
	// by R
	for n, sum := range R.colSums {
		if sum != replicaVBuckets[n] {
			return false
		}
	}

	return true
}

func TestVbmapProperties(t *testing.T) {
	setup(t)

	for _, gen := range allGenerators {

		check := func(params VbmapParams, seed int64) bool {
			return checkVbmapProperties(gen, params, seed)
		}

		err := quick.Check(check, &quick.Config{MaxCount: 100})
		if err != nil {
			t.Error(err)
		}

	}
}

type EqualTagsVbmapParams struct {
	VbmapParams
}

func equalTags(numNodes int, numTags int) (tags map[Node]Tag) {
	tags = make(map[Node]Tag)
	tagSize := numNodes / numTags
	tagResidue := numNodes % numTags

	node := 0
	tag := 0
	for numTags > 0 {
		for i := 0; i < tagSize; i++ {
			tags[Node(node)] = Tag(tag)
			node++
		}

		if tagResidue != 0 {
			tags[Node(node)] = Tag(tag)
			node++
			tagResidue--
		}

		tag++
		numTags--
	}

	return
}

func (_ EqualTagsVbmapParams) Generate(rand *rand.Rand, size int) reflect.Value {
	numNodes := rand.Int()%100 + 1
	// number of tags is in range [2, numNodes]
	numTags := rand.Int()%(numNodes-1) + 2

	params = VbmapParams{
		Tags:        equalTags(numNodes, numTags),
		NumNodes:    numNodes,
		NumSlaves:   10,
		NumVBuckets: 1024,
		NumReplicas: 1,
	}
	normalizeParams(&params)

	return reflect.ValueOf(EqualTagsVbmapParams{params})
}

func checkRIPropertiesTagAware(gen RIGenerator, params VbmapParams) bool {
	RI, err := gen.Generate(params)
	if err != nil {
		switch err {
		case ErrorNoSolution:
			diag.Printf("Couldn't find a solution for params %s", params)

			// cross-check using glpk generator
			gen := makeGlpkRIGenerator()

			// if glpk can find a solution then report an error
			_, err = gen.Generate(params)
			if err == nil {
				return false
			}

			return true
		default:
			return false
		}
	}

	for i, row := range RI {
		for j, elem := range row {
			if elem {
				if params.Tags[Node(i)] == params.Tags[Node(j)] {
					return false
				}
			}
		}
	}

	return true
}

func TestRIPropertiesTagAware(t *testing.T) {
	setup(t)

	for _, gen := range tagAwareGenerators {
		check := func(params EqualTagsVbmapParams) bool {
			return checkRIPropertiesTagAware(gen, params.VbmapParams)
		}

		err := quick.Check(check, &quick.Config{MaxCount: 100})
		if err != nil {
			t.Error(err)
		}

	}
}
