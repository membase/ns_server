package main

import (
	"fmt"
	"io"
	"io/ioutil"
	"math/rand"
	"os"
	"os/exec"
	"text/template"
)

// RI generator that uses GLPK to find satisfying matrix RI.
type GlpkRIGenerator struct {
	DontAcceptRIGeneratorParams
}

func makeGlpkRIGenerator() *GlpkRIGenerator {
	return &GlpkRIGenerator{}
}

func (_ GlpkRIGenerator) String() string {
	return "glpk"
}

const model = `
param nodes, integer, >= 1;
param slaves, integer, >= 0;

param tags_count, integer, >= 1;
param tags{0..nodes-1}, integer, >= 0, < tags_count;

var RI{i in 0..nodes-1, j in 0..nodes-1}, binary;

subject to zeros{i in 0..nodes-1, j in 0..nodes-1: tags[i] == tags[j]}: RI[i,j] = 0;
subject to active_balance{i in 0..nodes-1}: sum{j in 0..nodes-1} RI[i,j] = slaves;
subject to replica_balance{j in 0..nodes-1}: sum{i in 0..nodes-1} RI[i,j] = slaves;

var tag_max;
subject to tags_balance{i in 0..nodes-1, t in 0..tags_count-1}:
sum{j in 0..nodes-1} RI[i,j] * (if tags[j] == t then 1 else 0) <= tag_max;

minimize obj: tag_max;

solve;

for {i in 0..nodes-1}
{
  for {j in 0..nodes-1}
  {
    printf "%d\n", RI[i,j];
  }
}

end;
`

const dataTemplate = `
data;

param nodes := {{ .NumNodes }};
param slaves := {{ .NumSlaves }};
param tags_count := {{ .Tags.TagsCount }};
param tags := {{ range $node, $tag := .Tags }}{{ $node }} {{ $tag }} {{ end }};

end;
`

type GlpkResult uint

func genDataFile(file io.Writer, params VbmapParams) error {
	tmpl := template.Must(template.New("data").Parse(dataTemplate))
	return tmpl.Execute(file, params)
}

func readSolution(params VbmapParams, outPath string) (RI, error) {
	output, err := os.Open(outPath)
	if err != nil {
		return nil, err
	}
	defer output.Close()

	var values []int = make([]int, params.NumNodes*params.NumNodes)

	for i := range values {
		_, err := fmt.Fscan(output, &values[i])
		if err == io.EOF && i == 0 {
			return nil, ErrorNoSolution
		}

		if err != nil {
			return nil, fmt.Errorf("Invalid GLPK output (%s)", err.Error())
		}
	}

	result := make([][]bool, params.NumNodes)
	for i := range result {
		for _, v := range values[i*params.NumNodes : (i+1)*params.NumNodes] {
			value := (v != 0)
			result[i] = append(result[i], value)
		}
	}

	return result, nil
}

func (_ GlpkRIGenerator) Generate(params VbmapParams) (RI, error) {
	dataFile, err := ioutil.TempFile("", "vbmap_glpk_data")
	if err != nil {
		return nil, fmt.Errorf("Couldn't create data file: %s", err.Error())
	}
	defer func() {
		dataFile.Close()
		os.Remove(dataFile.Name())
	}()

	if err := genDataFile(dataFile, params); err != nil {
		return nil, fmt.Errorf("Couldn't generate data file %s: %s",
			dataFile.Name(), err.Error())
	}

	outputFile, err := ioutil.TempFile("", "vbmap_glpk_output")
	if err != nil {
		return nil, fmt.Errorf("Couldn't create output file: %s", err.Error())
	}
	outputFile.Close()
	defer os.Remove(outputFile.Name())

	modelFile, err := ioutil.TempFile("", "vbmap_glpk_model")
	if err != nil {
		return nil, fmt.Errorf("Couldn't create model file: %s", err.Error())
	}
	modelFile.Close()
	defer os.Remove(modelFile.Name())

	err = ioutil.WriteFile(modelFile.Name(), []byte(model), os.FileMode(0644))
	if err != nil {
		return nil, fmt.Errorf("Couldn't populate model file %s: %s",
			modelFile.Name(), err.Error())
	}

	cmd := exec.Command("glpsol",
		"--model", modelFile.Name(),
		"--tmlim", "10",
		"--data", dataFile.Name(),
		"--display", outputFile.Name(),
		"--seed", fmt.Sprint(rand.Int31()),
		"--mipgap", "0.5")

	terminal, err := cmd.CombinedOutput()

	diag.Printf("=======================GLPK output=======================")
	diag.Printf("%s", string(terminal))
	diag.Printf("=========================================================")

	if err != nil {
		return nil, err
	}

	return readSolution(params, outputFile.Name())
}
