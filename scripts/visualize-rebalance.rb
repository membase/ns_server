#!/usr/bin/env ruby

require 'json'
require 'pp'

begin
  filename = ARGV[0] || (raise "need filename arg")
  $events = IO.readlines(filename).map {|l| JSON.parse(l)}
  $events = $events.sort_by {|e| e["ts"]}
end

rebalance_end = $events.reverse.detect {|ev| ev["type"] == "bucketRebalanceEnded"}

raise "couln't find rebalance" unless rebalance_end

rebalance_start = $events.reverse.detect {|ev| ev["type"] == "bucketRebalanceStarted" && ev["pid"] == rebalance_end["pid"]}

raise "cound't locate start of rebalance: #{rebalance_end.inspect}" unless rebalance_end

raise unless rebalance_start["ts"] <= rebalance_end["ts"]

range = (rebalance_start["ts"]..rebalance_end["ts"])
$events = $events.select {|ev| range.include? ev["ts"]}

$in_flight = {}
$backfilled = {}

$output_events = []

$now = nil

def output_event(type, subtype, node)
  raise unless $now
  $output_events << [$now, type, subtype, node]
end

$vbucket_to_ev = {}

def inc_node(hash, node, by)
  hash[node] ||= 0
  hash[node] += by
end

def note_move_started_on(node)
  $in_flight[node] ||= 0
  if $in_flight[node] == 0
    output_event :move, :start, node
  end
  output_event :backfill, :start, node
  $in_flight[node] += 1
end

def note_backfill_done_on(node)
  raise unless $in_flight[node] > 0
  output_event :backfill, :done, node
end

def note_move_done_on(node)
  raise unless $in_flight[node] > 0
  $in_flight[node] -= 1
  if $in_flight[node] == 0
    output_event :move, :done, node
  end
end

$backfill_ts_to_vbucket = {}

$events.each do |ev|
  type = ev["type"]
  $now = ev["ts"]
  case type
  when "vbucketMoveStart"
    $vbucket_to_ev[ev["vbucket"]] = ev
    $backfill_ts_to_vbucket[$now] = ev["vbucket"]
    note_move_started_on(ev["chainBefore"][0])
    note_move_started_on(ev["chainAfter"][0])
  when "vbucketMoveDone"
    oev = $vbucket_to_ev[ev["vbucket"]] || raise
    note_move_done_on(oev["chainBefore"][0])
    note_move_done_on(oev["chainAfter"][0])
  when "checkpointWaitingEnded"
    next if $backfilled[ev["vbucket"]]
    $backfilled[ev["vbucket"]] = true
    oev = $vbucket_to_ev[ev["vbucket"]] || raise
    note_backfill_done_on(oev["chainBefore"][0])
    note_backfill_done_on(oev["chainAfter"][0])
  else
    next
  end
end


$output_events = $output_events.sort do |(now_a, _, subtype_a, _), (now_b, _, subtype_b, _)|
  rv = now_a - now_b
  if rv == 0
    rv = case [subtype_a, subtype_b]
         when [:done, :start]
           -1
         when [:done, :done]
           0
         when [:start, :start]
           0
         else
           1
         end
  end
  rv
end

# pp $output_events

$timelines = {}

$open_things = {}

$backfill_vbuckets = []

$output_events.each do |(ts, type, subtype, node)|
  $timelines[node] ||= []
  k = [node, type]
  case subtype
  when :start
    $open_things[k] = ts
  when :done
    start_ts = $open_things[k]
    raise "shit: #{k.inspect} #{ts}" unless start_ts
    $open_things.delete k
    entry = [start_ts, ts, type]
    $timelines[node] << entry
    if type == :backfill
      $backfill_vbuckets << [$backfill_ts_to_vbucket[start_ts], *entry]
    end
  end
end

raise unless $open_things.keys.empty?

longest_backfills = $backfill_vbuckets.sort_by {|r| r[1] - r[2]}.uniq

puts "longest backfills:"
top_of_longest = longest_backfills.map {|r| r.dup << r[2] - r[1]}
pp top_of_longest[0...30]

puts "sum of times: #{top_of_longest.inject(0) {|s,r| r[-1]+s}}, #{top_of_longest[0...30].inject(0) {|s,r| r[-1]+s}}"


$timelines = $timelines.to_a.map do |(node, events)|
  new_events = events.sort_by {|(start, done,_)| [start, start - done]}
  [node, new_events]
end.sort

$latest_time = $timelines.flatten.select {|e| e.kind_of?(Numeric)}.max
$earliest_time = $timelines.flatten.select {|e| e.kind_of?(Numeric)}.min

def ts_to_y(ts)
  100 + (ts - $earliest_time) / ($latest_time - $earliest_time) * 10000
end

# pp $timelines

require 'rasem'

def do_svg(filename, width, height)
  inst = Rasem::SVGImage.new(width, height)
  yield inst
  inst.close
  File.open(filename, "w") do |f|
    f << inst.output
  end
end

$width_per_node = 200

do_svg(ARGV[0]+".svg", $width_per_node * $timelines.size, 12000) do |img|
  $timelines.each_with_index do |(_node, lines), idx|
    pos = (idx + 0.5) * $width_per_node
    # general timeline
    img.line pos, 0, pos, 11000, :'stroke-width' => 1, :opacity => 1.0, :stroke => '#000'

    lines.each do |(start, done, type)|
      start_y = ts_to_y(start)
      done_y = ts_to_y(done)
      case type
      when :move
        img.line pos, start_y, pos, done_y, :'stroke-width' => 12, :opacity => 1.0, :stroke => 'yellow'
      when :backfill
        img.line(pos-32, start_y, pos+32, start_y, :'stroke-width' => 1, :stroke => 'black')
        img.line pos, start_y, pos, done_y, :'stroke-width' => 24, :opacity => 1.0, :stroke => 'green'
      else
        img.line pos, start_y, pos, done_y, :'stroke-width' => 32, :opacity => 1.0, :stroke => 'red'
      end
    end
  end
end
