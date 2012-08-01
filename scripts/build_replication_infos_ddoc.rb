#!/usr/bin/env ruby

require 'stringio'

functions = {
  :map => <<-HERE,
function (d, meta) {
  d._id = meta.id;
  if (d.type === 'xdc') {
    emit([d._id], d);
  } else if (d.node && d.replication_doc_id && d.replication_fields) {
    d.replication_fields._id = d.replication_doc_id;
    emit([d.replication_doc_id, d._id], d);
  }
}
  HERE
  :reduce => <<-HERE,
function (keys, values, rereduce) {
  var result_state = null;
  var state_ts;
  var have_replicator_doc = false;
  var count = 0;
  var replication_fields = null;

  function minTS(state_ts, ts) {
    return (state_ts == null) ? ts : (ts == null) ? state_ts : (ts < state_ts) ? ts : state_ts;
  }

  function setState(state, ts) {
    if (result_state === state) {
      state_ts = minTS(state_ts, ts);
    } else {
      result_state = state;
      state_ts = ts;
    }
  }

  function addReplicationFields(a, b) {
    if (a === undefined || b === undefined) {
      return;
    }
    var rv = {
      _id: a._id,
      source: a.source,
      target: a.target,
      continuous: a.continuous
    }
    if (b === null) {
      return rv;
    }
    if (rv._id !== b._id
        || rv.source !== b.source
        || rv.target !== b.target
        || rv.continuous !== b.continuous) {
      return;
    }
    return rv;
  }

  values.forEach(function (d) {
    if (d.type === 'xdc') {
      have_replicator_doc = true;
      replication_fields = addReplicationFields(d, replication_fields);
      return;
    }
    replication_fields = addReplicationFields(d.replication_fields, replication_fields);
    have_replicator_doc = d.have_replicator_doc || have_replicator_doc;
    count += d.count ? d.count : 1;
    var state = d._replication_state;
    var ts = d._replication_state_time;
    if (state === undefined) {
      setState(state, ts);
    } else if (result_state === undefined) {
    } else if (state === 'triggered') {
      setState(state, ts);
    } else if (result_state === 'triggered') {
    } else if (state === 'cancelled') {
      setState(state, ts);
    } else if (result_state === 'cancelled') {
    } else if (state === 'error') {
      setState(state, ts);
    } else if (result_state === 'error') {
    } else if (state === 'completed') {
      setState(state, ts);
    }
  });

  // NOTE: null signals lack of rows here, undefined means any row had
  // undefined
  if (result_state === null) {
    result_state = undefined;
  }

  // NOTE: null signals lack of rows here, undefined means conflicting
  // fields
  if (replication_fields === null) {
    replication_fields = undefined;
  }

  return {_replication_state: result_state,
          _replication_state_time: state_ts,
          replication_fields: replication_fields,
          have_replicator_doc: have_replicator_doc,
          count: count};
}
  HERE
}

def output_multi_string(string)
  lines = StringIO.new(string).readlines
  lines.each {|l| puts(l.inspect)}
end

puts "-define(REPLICATION_INFOS_MAP, <<"
output_multi_string(functions[:map])
puts ">>)."
puts
puts "-define(REPLICATION_INFOS_REDUCE, <<"
output_multi_string(functions[:reduce])
puts ">>)."
