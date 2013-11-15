package main

import (
	"bytes"
	"fmt"
	"io"
	"io/ioutil"
	"sort"
)

type MaxFlowRIGenerator struct {
	dotPath string
}

func makeMaxFlowRIGenerator() *MaxFlowRIGenerator {
	return &MaxFlowRIGenerator{dotPath: ""}
}

func (_ MaxFlowRIGenerator) String() string {
	return "maxflow"
}

func (gen *MaxFlowRIGenerator) SetParams(params map[string]string) error {
	for k, v := range params {
		switch k {
		case "dot":
			gen.dotPath = v
		default:
			return fmt.Errorf("unsupported parameter '%s'", k)
		}
	}

	return nil
}

func (gen MaxFlowRIGenerator) Generate(params VbmapParams) (RI RI, err error) {
	g := buildFlowGraph(params)

	diag.Print("Constructed flow graph.\n")
	diag.Print(g.graphStats)

	g.maximizeFlow()

	if gen.dotPath != "" {
		err := g.dot(gen.dotPath)
		if err != nil {
			diag.Printf("Couldn't create dot file %s: %s",
				gen.dotPath, err.Error())
		}
	}

	if !g.isSaturated() {
		return nil, ErrorNoSolution
	}

	return g.toRI(), nil
}

func buildFlowGraph(params VbmapParams) (g *graph) {
	g = makeGraph(params)
	tags := params.Tags.TagsList()
	tagsNodes := params.Tags.TagsNodesMap()

	maxReplicationsPerTag := 0
	if params.NumReplicas != 0 {
		maxReplicationsPerTag = params.NumSlaves / params.NumReplicas
	}

	for _, node := range params.Nodes() {
		nodeTag := params.Tags[node]
		nodeSrcV := nodeSourceVertex(node)
		nodeSinkV := nodeSinkVertex(node)

		g.addSimpleEdge(source, nodeSrcV, params.NumSlaves)
		g.addSimpleEdge(nodeSinkV, sink, params.NumSlaves)

		for _, tag := range tags {
			if tag == nodeTag {
				continue
			}

			tagNodesCount := len(tagsNodes[tag])
			tagCapacity := Min(tagNodesCount, maxReplicationsPerTag)

			tagV := tagVertex(tag)
			g.addEdge(nodeSrcV, tagV, tagCapacity)
		}
	}

	for _, tag := range tags {
		tagNodes := tagsNodes[tag]
		tagV := tagVertex(tag)
		tagNodesCount := len(tagNodes)
		tagEdgeCapacity := params.NumNodes - tagNodesCount

		for _, tagNode := range tagNodes {
			tagNodeV := nodeSinkVertex(tagNode)

			g.addEdge(tagV, tagNodeV, tagEdgeCapacity)
		}
	}

	return
}

type graphVertex interface {
	fmt.Stringer
}

type simpleVertex string

func (v simpleVertex) String() string {
	return string(v)
}

const (
	source simpleVertex = "source"
	sink   simpleVertex = "sink"
)

type tagVertex Tag

func (v tagVertex) String() string {
	return fmt.Sprintf("tag_%d", int(v))
}

type nodeSourceVertex Node

func (v nodeSourceVertex) String() string {
	return fmt.Sprintf("node_%d_source", int(v))
}

type nodeSinkVertex Node

func (v nodeSinkVertex) String() string {
	return fmt.Sprintf("node_%d_sink", int(v))
}

type graphEdge struct {
	src graphVertex
	dst graphVertex

	capacity    int
	flow        int
	reverseEdge *graphEdge

	// is this an auxiliary edge?
	aux bool
}

func (edge graphEdge) String() string {
	return fmt.Sprintf("%s->%s", edge.src, edge.dst)
}

func (edge graphEdge) residual() int {
	return edge.capacity - edge.flow
}

func (edge graphEdge) mustREdge() *graphEdge {
	if edge.reverseEdge == nil {
		panic(fmt.Sprintf("Edge %s does not have a reverse edge", edge))
	}

	return edge.reverseEdge
}

func (edge *graphEdge) pushFlow(flow int) {
	residual := edge.residual()
	if flow > residual {
		panic(fmt.Sprintf("Trying to push flow %d "+
			"via edge %s with residual capacity %d",
			flow, edge, residual))
	}

	edge.flow += flow
	if edge.reverseEdge != nil {
		edge.reverseEdge.flow -= flow
	}
}

func (edge graphEdge) isSaturated() bool {
	return edge.residual() == 0
}

type augPath []*graphEdge

func (path *augPath) addEdge(edge *graphEdge) {
	*path = append(*path, edge)
}

func (path *augPath) removeLastEdge() (edge *graphEdge) {
	n := len(*path)
	if n == 0 {
		panic("Removing edge from empty path")
	}

	edge = (*path)[n-1]
	*path = (*path)[0 : n-1]

	return
}

func (path augPath) capacity() (result int) {
	if len(path) == 0 {
		panic("capacity called on empty path")
	}

	result = path[0].residual()
	for _, edge := range path {
		residual := edge.residual()
		if residual < result {
			result = residual
		}
	}

	return
}

func (path *augPath) truncate(i int) {
	if i >= len(*path) {
		panic("index out of range in truncate")
	}

	*path = (*path)[0:i]
}

type graphVertexData struct {
	allEdges  []*graphEdge
	firstEdge int
}

func makeGraphVertexData() *graphVertexData {
	return &graphVertexData{allEdges: []*graphEdge{}, firstEdge: 0}
}

func (v graphVertexData) edges() []*graphEdge {
	return v.allEdges[v.firstEdge:]
}

func (v *graphVertexData) addEdge(edge *graphEdge) {
	v.allEdges = append(v.allEdges, edge)
}

func (v *graphVertexData) forgetFirstEdge() {
	v.firstEdge += 1
}

func (v *graphVertexData) reset() {
	v.firstEdge = 0
}

type graphStats struct {
	numVertices int
	numEdges    int
}

func (stats graphStats) String() string {
	return fmt.Sprintf("Graph stats:\n\tVertices: %d\n\tEdges: %d\n",
		stats.numVertices, stats.numEdges)
}

func (stats *graphStats) noteVertexAdded() {
	stats.numVertices += 1
}

func (stats *graphStats) noteEdgeAdded() {
	stats.numEdges += 1
}

type maxflowStats struct {
	iteration   int
	numAdvances int
	numRetreats int
	numAugments int
	numEdges    int
}

func (stats maxflowStats) String() string {
	return fmt.Sprintf("Max flow stats:\n\tCurrent iteration: %d\n"+
		"\tNumber of advances: %d\n\tNumber of retreats: %d\n"+
		"\tNumber of augments: %d\n"+
		"\tTotal number of edges processed: %d\n",
		stats.iteration, stats.numAdvances,
		stats.numRetreats, stats.numAugments, stats.numEdges)
}

func (stats *maxflowStats) reset() {
	stats.iteration = 0
	stats.numAdvances = 0
	stats.numRetreats = 0
	stats.numAugments = 0
	stats.numEdges = 0
}

func (stats *maxflowStats) nextIteration() {
	iter := stats.iteration
	stats.reset()
	stats.iteration = iter + 1
}

func (stats *maxflowStats) noteAdvance() {
	stats.numAdvances += 1
}

func (stats *maxflowStats) noteRetreat() {
	stats.numRetreats += 1
}

func (stats *maxflowStats) noteAugment() {
	stats.numAugments += 1
}

func (stats *maxflowStats) noteEdgeProcessed() {
	stats.numEdges += 1
}

type graph struct {
	params    VbmapParams
	vertices  map[graphVertex]*graphVertexData
	distances map[graphVertex]int
	flow      int

	graphStats
	maxflowStats
}

func makeGraph(params VbmapParams) (g *graph) {
	g = &graph{}
	g.vertices = make(map[graphVertex]*graphVertexData)
	g.distances = make(map[graphVertex]int)
	g.params = params
	return
}

func (g *graph) bfs() bool {
	queue := []graphVertex{source}
	seen := make(map[graphVertex]bool)

	seen[source] = true
	g.distances[source] = 0

	for len(queue) != 0 {
		v := queue[0]
		d := g.distances[v]

		queue = queue[1:]

		for _, edge := range g.vertices[v].edges() {
			if edge.isSaturated() {
				continue
			}

			_, present := seen[edge.dst]
			if !present {
				dst := edge.dst

				queue = append(queue, dst)
				seen[dst] = true
				g.distances[dst] = d + 1
			}
		}
	}

	_, seenSink := seen[sink]
	return seenSink
}

func (g *graph) dfsPath(from graphVertex, path *augPath) bool {
	if from == sink {
		return true
	}

	d := g.distances[from]

	fromData := g.vertices[from]

	for _, edge := range fromData.edges() {
		g.noteEdgeProcessed()

		dst := edge.dst

		if g.distances[dst] == d+1 && !edge.isSaturated() {
			g.noteAdvance()

			path.addEdge(edge)
			if g.dfsPath(dst, path) {
				return true
			}

			path.removeLastEdge()
		}

		fromData.forgetFirstEdge()
	}

	g.noteRetreat()
	return false
}

func (g *graph) augmentFlow() bool {
	for _, vertexData := range g.vertices {
		vertexData.reset()
	}

	if !g.bfs() {
		return false
	}

	path := augPath(nil)
	v := graphVertex(source)

	for {
		pathFound := g.dfsPath(v, &path)
		if pathFound {
			capacity := path.capacity()
			g.flow += capacity
			firstSaturatedEdge := -1

			for i, edge := range path {
				edge.pushFlow(capacity)
				if firstSaturatedEdge == -1 && edge.isSaturated() {
					firstSaturatedEdge = i
				}
			}

			g.noteAugment()

			if firstSaturatedEdge == -1 {
				panic("No saturated edge on augmenting path")
			}

			v = path[firstSaturatedEdge].src
			path.truncate(firstSaturatedEdge)
		} else {
			if v == source {
				break
			} else {
				g.distances[v] = -1
				edge := path.removeLastEdge()
				v = edge.src
			}
		}
	}

	return true
}

func (g *graph) addVertex(vertex graphVertex) {
	_, present := g.vertices[vertex]
	if !present {
		g.noteVertexAdded()
		g.vertices[vertex] = makeGraphVertexData()
	}
}

func (g *graph) addSimpleEdge(src graphVertex, dst graphVertex, capacity int) {
	g.addVertex(src)
	g.addVertex(dst)

	edge := &graphEdge{src: src, dst: dst,
		capacity: capacity, flow: 0, reverseEdge: nil}

	g.noteEdgeAdded()
	g.vertices[src].addEdge(edge)
}

func (g *graph) addEdge(src graphVertex, dst graphVertex, capacity int) {
	g.addVertex(src)
	g.addVertex(dst)

	edge := &graphEdge{src: src, dst: dst, capacity: capacity, flow: 0}
	redge := &graphEdge{src: dst, dst: src, capacity: 0, flow: 0, aux: true}

	edge.reverseEdge = redge
	redge.reverseEdge = edge

	g.vertices[src].addEdge(edge)
	g.vertices[dst].addEdge(redge)

	g.noteEdgeAdded()
	g.noteEdgeAdded()
}

func (g graph) edges() (result []*graphEdge) {
	for _, vertexData := range g.vertices {
		for _, edge := range vertexData.edges() {
			result = append(result, edge)
		}
	}

	return
}

func (g *graph) maximizeFlow() {
	g.maxflowStats.reset()

	for {
		if augmented := g.augmentFlow(); !augmented {
			break
		}

		diag.Print(g.maxflowStats.String())
		g.maxflowStats.nextIteration()
	}
}

func (g graph) isSaturated() bool {
	expectedFlow := g.params.NumNodes * g.params.NumSlaves
	return g.flow == expectedFlow
}

type nodeCount struct {
	node  Node
	count int
}

type nodeCountSlice []nodeCount

func (a nodeCountSlice) Len() int           { return len(a) }
func (a nodeCountSlice) Less(i, j int) bool { return a[i].count > a[j].count }
func (a nodeCountSlice) Swap(i, j int)      { a[i], a[j] = a[j], a[i] }

func (g graph) toRI() (RI RI) {
	RI = make([][]bool, g.params.NumNodes)

	for i := range g.params.Nodes() {
		RI[i] = make([]bool, g.params.NumNodes)
	}

	for _, tag := range g.params.Tags.TagsList() {
		tagV := tagVertex(tag)

		inRepsCounts := make(nodeCountSlice, 0)
		outRepsCounts := make(nodeCountSlice, 0)

		for _, edge := range g.vertices[tagV].edges() {
			if !edge.aux {
				// edge to node sink vertex
				dstNode := Node(edge.dst.(nodeSinkVertex))

				count := nodeCount{dstNode, edge.flow}
				inRepsCounts = append(inRepsCounts, count)
			} else {
				// reverse edge to node source vertex
				redge := edge.mustREdge()
				srcNode := Node(redge.src.(nodeSourceVertex))

				count := nodeCount{srcNode, redge.flow}
				outRepsCounts = append(outRepsCounts, count)
			}
		}

		sort.Sort(outRepsCounts)

		slavesLeft := len(inRepsCounts)
		slaveIx := 0

		for _, pair := range outRepsCounts {
			count := pair.count
			srcNode := int(pair.node)

			for count > 0 {
				if slavesLeft == 0 {
					panic(fmt.Sprintf("Ran out of slaves "+
						"on tag %v", tag))
				}

				for inRepsCounts[slaveIx].count == 0 {
					slaveIx = (slaveIx + 1) % len(inRepsCounts)
				}

				dstNode := int(inRepsCounts[slaveIx].node)

				if RI[srcNode][dstNode] {
					panic(fmt.Sprintf("Forced to use the "+
						"same slave %d twice (tag %v)",
						dstNode, tag))
				}

				RI[srcNode][dstNode] = true
				count -= 1

				inRepsCounts[slaveIx].count -= 1
				if inRepsCounts[slaveIx].count == 0 {
					slavesLeft -= 1
				}

				slaveIx = (slaveIx + 1) % len(inRepsCounts)
			}
		}
	}

	return
}

func (g graph) dot(path string) (err error) {
	buffer := &bytes.Buffer{}

	fmt.Fprintf(buffer, "digraph G {\n")
	fmt.Fprintf(buffer, "rankdir=LR;\n")
	fmt.Fprintf(buffer, "labelloc=t; labeljust=l; ")
	fmt.Fprintf(buffer, "label=\"flow = %d\";\n", g.flow)

	groupVertices(buffer, []graphVertex{source}, "source")
	groupVertices(buffer, []graphVertex{sink}, "sink")

	nodeSrcVertices := make([]graphVertex, 0)
	nodeSinkVertices := make([]graphVertex, 0)
	tagVertices := make([]graphVertex, 0)

	for _, node := range g.params.Nodes() {
		nodeSrcVertices = append(nodeSrcVertices, nodeSourceVertex(node))
		nodeSinkVertices = append(nodeSinkVertices, nodeSinkVertex(node))
	}

	for _, tag := range g.params.Tags.TagsList() {
		tagVertices = append(tagVertices, tagVertex(tag))
	}

	groupVertices(buffer, nodeSrcVertices, "same")
	groupVertices(buffer, tagVertices, "same")
	groupVertices(buffer, nodeSinkVertices, "same")

	for _, edge := range g.edges() {
		style := "solid"
		if edge.aux {
			style = "dashed"
		}

		color := "red"
		if edge.residual() > 0 {
			color = "darkgreen"
		}

		fmt.Fprintf(buffer,
			"%s -> %s [label=\"%d (cap %d)\", decorate,"+
				" style=%s, color=%s];\n",
			edge.src, edge.dst, edge.flow,
			edge.capacity, style, color)
	}

	fmt.Fprintf(buffer, "}\n")

	return ioutil.WriteFile(path, buffer.Bytes(), 0644)
}

func groupVertices(w io.Writer, vertices []graphVertex, rank string) {
	fmt.Fprintf(w, "{\n")
	fmt.Fprintf(w, "rank=%s;\n", rank)

	for _, v := range vertices {
		fmt.Fprintf(w, "%s;\n", v)
	}

	fmt.Fprintf(w, "}\n")
}
