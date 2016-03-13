package main

import (
	"flag"
	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
)

func getAppScript(n *html.Node) string {
	if n.Type == html.ElementNode && n.Data == "script" {
		for _, a := range n.Attr {
			if a.Key == "src" && strings.HasPrefix(string(a.Val), "app") {
				return a.Val
			}
		}
	}
	return ""
}

func isPluggableUIInjectionComment(n *html.Node) bool {
	return n.Type == html.CommentNode &&
		n.Data == " Inject head.frag.html file content for Pluggable UI components here "
}

func isWhitespaceText(n *html.Node) bool {
	return n.Type == html.TextNode && strings.TrimSpace(n.Data) == ""
}

func makeAppMinJsNode() *html.Node {
	attrs := []html.Attribute{{Key: "src", Val: "app.min.js"}}
	return &html.Node{Type: html.ElementNode, Data: "script", DataAtom: atom.Data, Attr: attrs}
}

func makeNewLine() *html.Node {
	return &html.Node{Type: html.TextNode, Data: "\n"}
}

type context struct {
	FoundFirstAppScript bool
}

type result struct {
	PluggableInjectionCount int
	AppScripts              []string
}

// Minifies node and returns a minification Result.
func doMinify(node *html.Node, ctx *context) result {
	prevWasWhitespace := false
	var next *html.Node
	rv := result{}
	for child := node.FirstChild; child != nil; child = next {
		next = child.NextSibling
		appScript := getAppScript(child)
		if appScript != "" {
			if !ctx.FoundFirstAppScript {
				ctx.FoundFirstAppScript = true
				node.InsertBefore(makeAppMinJsNode(), child)
				node.InsertBefore(makeNewLine(), child)
			}
			rv.AppScripts = append(rv.AppScripts, appScript)
			node.RemoveChild(child)
		} else if isWhitespaceText(child) && node.Type == html.ElementNode && node.Data == "head" {
			if !prevWasWhitespace {
				node.InsertBefore(makeNewLine(), child)
			}
			node.RemoveChild(child)
			prevWasWhitespace = true
		} else {
			if isPluggableUIInjectionComment(child) {
				rv.PluggableInjectionCount++
			} else {
				childResult := doMinify(child, ctx)
				rv.AppScripts = append(rv.AppScripts, childResult.AppScripts...)
				rv.PluggableInjectionCount += childResult.PluggableInjectionCount
			}
			prevWasWhitespace = false
		}
	}
	return rv
}

func closeFile(file *os.File, sync bool) {
	if sync {
		err := file.Sync()
		if err != nil {
			log.Printf("Error flushing file: %v", err)
		}
	}
	if err := file.Close(); err != nil {
		panic(err)
	}
}

func createAppMinJsFile(appScripts []string, dir string) {
	appMinJsWrtr, err := os.Create(filepath.Join(dir, "app.min.js"))
	if err != nil {
		log.Fatal(err)
	}
	defer closeFile(appMinJsWrtr, true)
	for _, script := range appScripts {
		file, err := os.Open(filepath.Join(dir, script))
		if err != nil {
			log.Fatal(err)
		}
		defer closeFile(file, false)
		_, err = io.Copy(appMinJsWrtr, file)
		if err != nil {
			log.Fatalf("Error copying script file '%v' to app.min.js: %v", script, err)
		}
	}
}

func createIndexMinHTMLFile(document *html.Node, dir string) {
	wrtr, err := os.Create(filepath.Join(dir, "index.min.html"))
	if err != nil {
		log.Fatalf("Error: could not open file for write: %v", err)
	}
	defer closeFile(wrtr, true)
	html.Render(wrtr, document)
}

func main() {
	indexHTML := flag.String("index-html", "", "path to index.html file (required)")
	flag.Parse()
	log.SetFlags(0)

	if *indexHTML == "" {
		log.Printf("Error: path to index.html file must be specified\n")
		flag.Usage()
		os.Exit(1)
	}

	rdr, err := os.Open(*indexHTML)
	if err != nil {
		log.Fatalf("Error: Can't open file: %v", err)
	}
	defer closeFile(rdr, false)

	dir := filepath.Dir(*indexHTML)
	doc, err := html.Parse(rdr)
	if err != nil {
		log.Fatalf("Error during parse of '%v': %v", *indexHTML, err)
	}
	rv := doMinify(doc, &context{})
	if rv.PluggableInjectionCount != 1 {
		log.Fatalf("Error: number of pluggable injection comments found was %v, should be 1",
			rv.PluggableInjectionCount)
	}
	createAppMinJsFile(rv.AppScripts, dir)
	createIndexMinHTMLFile(doc, dir)
}
