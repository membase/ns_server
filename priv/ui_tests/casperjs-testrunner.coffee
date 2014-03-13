# Globals: phantom, CasperError, patchRequire, global, require:true, casper:true

usage = ->
  console.log "usage:"
  console.log "    phantomjs [path to casperjs/bootstrap.js] --casper-path=[path to casperjs folder] --cli [path to this file] [path to suites, default is ./suite/] [options]"
  console.log "    ...ns_server/scripts/only-web.rb -t (run ns_server with tests)"
  console.log ""
  console.log "options:"
  console.log "    --version                        forvce current UI version (default is current)"
  console.log "    --roadmin                        run tests as read only admin (default is admin)"
  console.log "    --mock-the-clock-root            path to mockTheClock (default is ...ns_server/priv/js-unit-tests)"
  console.log "    --resemble-js-root               path to ResembleJS (default is ...ns_server/priv/ui_tests/deps/resemblejs)"
  console.log "    --screenshots-output-path        path to screenshots (default is ...ns_server/scripts/tests/screenshots_output)"
  console.log "    --screenshots-compare            running screenshots comparison or not, true/false (default is true)"
  console.log "    --base-url                       url to ns_server index.html (default is http://localhost:9090/index.html)"
  console.log "    --usage                          this message"
  console.log "    --clean                          removing screenshots folder"
  console.log ""
  console.log "For more information see casperjs --help"
  phantom.exit 1

if !phantom && !phantom.casperLoaded
  console.log "This script must be invoked using the casperjs executable, take a look at ./casperjs-setup.sh"
  console.log ""
  do usage

require = patchRequire global.require

global.ns = ns = {}

fs = require "fs"
system = require "system"
casper = require("casper").create
  viewportSize: width: 1000, height: 800,
  exitOnError: true

ns.tester = require("tester").create casper
ns.phantomcss = require "phantomcss" #should be in casperjs/modules/

s = fs.separator
wd = fs.workingDirectory
opts = casper.cli.options

if opts["usage"]
  do usage

maybeNsRoot =
  !!wd.match("ns_server") and
  wd.replace /(.*ns_server).*/, "$1"

mockTheClockFolder =
  opts["mock-the-clock-root"] or
  "#{maybeNsRoot}#{s}priv#{s}js-unit-tests"

resembleJsFolder =
  opts["resemble-js-root"] or
  "#{maybeNsRoot}#{s}priv#{s}ui_tests#{s}deps#{s}resemblejs"

compareScreenShots =
  !opts["compare-screen-shots"]

ns.baseURL =
  opts["base-url"] or
  "http://localhost:9090#{s}index.html"

ns.screenshotsOutputPath =
  opts["screenshots-output-path"] or
  "#{maybeNsRoot}#{s}priv#{s}ui_tests#{s}screenshots_output"

if opts["clean"]
  if fs.isDirectory ns.screenshotsOutputPath
    fs.removeTree ns.screenshotsOutputPath
    ns.tester.bar "done!", "INFO_BAR"
  else
    ns.tester.bar "no folder, nothing to do", "INFO_BAR"
  phantom.exit 1

if !fs.isDirectory mockTheClockFolder
  throw new Error "--mock-the-clock-root must be specified"

if !fs.isDirectory resembleJsFolder
  throw new Error "--resemble-js-root must be specified"

if !fs.isFile "#{resembleJsFolder}#{s}resemble.js"
  throw new Error "can't find resemble.js file"

fullMockTheClockPath = ["binary-heap.js", "wrapped-date.js", "mockTheClock.js"].map (file) ->
  fullPath = "#{mockTheClockFolder}#{s}#{file}"
  if fs.isFile fullPath
    return fullPath
  throw new Error "Invalid mockTheClock path: #{file}"

if !casper.cli.args.length
  casper.cli.args = ["./suite/"]

testsSuiteCases = casper.cli.args.filter (path) ->
  if fs.isFile(path) or fs.isDirectory(path)
    return true
  throw new CasperError "Invalid test path: #{path}"

ns.phantomcss.init
  casper: casper
  screenshotRoot: ns.screenshotsOutputPath,
  failedComparisonsRoot: "#{ns.screenshotsOutputPath}#{s}failures",
  libraryRoot: resembleJsFolder,
  onPass: (test) ->
    ns.tester.pass "No changes found for screenshot #{test.filename}",
  onFail: (test) ->
    ns.tester.fail "Visual change found for screenshot #{test.filename} (#{test.mismatch}%)",
  onTimeout: (test) ->
    ns.tester.info "Could not complete image comparison for #{test.filename}"

ns.phantomcss.screenshot = (selector) ->
  name = ns.makeSafeFileName selector
  name += if fs.isFile "#{ns.screenshotsOutputPath}#{s}#{name}.png" then ".diff.png" else ".png"
  casper.capture "#{ns.screenshotsOutputPath}#{s}#{name}"

casper.tickFarAway = ->
  @evaluate ->
    Clock.tickFarAway()

casper.clickAndTick = ->
  @click.apply @, arguments
  @tickFarAway()

casper.thenClickAndTickWithShot = (selector, cb) ->
  @then -> @clickAndTick selector
  @then -> ns.phantomcss.screenshot selector
  if cb
    @then => cb.call(@)

ns.makeSafeFileName = (filename) ->
  filename.replace(/[^a-z0-9]/gi, '_').toLowerCase()

ns.setEnterprise = ->
  casper.evaluate ->
    DAL.cells.isEnterpriseCell.setValue true

ns.isBaseUrl = ->
  loadedBaseUrl = casper.evaluate ->
    window.location.origin + window.location.pathname
  ns.baseURL is loadedBaseUrl

ns.renderResults = (exit) ->
  @renderResults exit, undefined, casper.cli.get("xunit") or undefined
  if @options.failFast and @testResults.failures.length > 0
    casper.warn "Test suite failed fast, all tests may not have been executed."
  phantom.exit

casper.on "load.finished", ->
  if !ns.isBaseUrl()
    return
  fullMockTheClockPath.every (script) =>
    @page.injectJs script
  @evaluate ->
    Clock.hijack()
  if opts["roadmin"]
    @evaluate ->
      DAL.cells.isROAdminCell.setValue true
  if opts["version"]
    @evaluate ->
      majorMinor = opts["version"].split '.';
      version = encodeCompatVersion Number majorMinor[0], Number majorMinor[1]
      DAL.cells.compatVersion.setValue version

ns.tester.on "tests.complete", ->
  ns.renderResults.call @, !compareScreenShots
  if compareScreenShots
    @bar "screenshots comparison ", "INFO_BAR"
    ns.phantomcss.compareAll()
    casper.run () => ns.renderResults.call @, true

casper.on "capture.saved", (fileName) ->
  @warn "capture saved: #{fileName}"

ns.tester.runSuites.apply ns.tester, testsSuiteCases
