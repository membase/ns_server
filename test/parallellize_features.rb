#!/usr/bin/env ruby

Dir.chdir(File.dirname(__FILE__)+"/../features")

features = []
Dir['*.feature'].each do |name|
  IO.readlines(name).each_with_index do |line, i|
    next unless line =~ /^\s+Scenario:/
    features << "#{name}:#{i+1}"
  end
end

features_hash = features.inject({}) do |h,name|
  filtered_name = name.gsub(/[^a-zA-Z_0-9]/, '_')
  h[name] = "branch_#{filtered_name}"
  h
end

idx = -5
fragments = features_hash.map do |name, target_name|
  idx += 5
  tmpdir = "/tmp/ns_cucumber/#{Time.now.to_i}_#{target_name}"
  <<HERE
#{target_name}:
\trm -rf #{tmpdir}
\tmkdir -p #{tmpdir}
\tcp -rl .. #{tmpdir}
\t(cd #{tmpdir} && BASE_CACHE_PORT=#{12000 + idx*2} BASE_API_PORT=#{9000 + idx} cucumber features/#{name}) || (rm -rf #{tmpdir} && false)
\trm -rf #{tmpdir}

HERE
end

STDOUT << fragments.join("\n") << "\n\n"
STDOUT << "all_branches: #{features_hash.values.join(' ')}\n\n"
STDOUT << ".PHONY: all_branches #{features_hash.values.join(' ')} #{features_hash.values.map {|n| n+"_cleanup"}.join(' ')}\n"
