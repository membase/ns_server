s = fs.separator
currentWorkingDirectory = fs.workingDirectory
nsServerRoot = currentWorkingDirectory.split("ns_server")[0] + "ns_server" + s

mockTheClockFolder = "priv" + s + "js-unit-tests" + s
mockTheClockFiles = [
  "binary-heap.js",
  "wrapped-date.js",
  "mockTheClock.js"
]
fullMockTheClockPath = for file in mockTheClockFiles
                          nsServerRoot + mockTheClockFolder + file
casper.exit 1 for path in fullMockTheClockPath when !checkIncludeFile path

casper.baseURL = casper.cli.options["base-url"] || "localhost:9090" + s + "index.html"
casper.screenshotsOutputPath = casper.cli.options["screenshots-output-path"] || (nsServerRoot + "scripts" + s + "tests" + s + "screenshots-output" + s)

casper.tickFarAway = ->
  @evaluate () ->
      Clock.tickFarAway()

casper.on 'load.finished', () ->
  @page.injectJs(script) for script in fullMockTheClockPath
  @evaluate () ->
    Clock.hijack()

casper.on 'capture.saved', (fileName) ->
  @warn "Screen captured: " + fileName

casper.options.viewportSize = width: 1000, height: 800

casper.test.done()
