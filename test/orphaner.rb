#!/usr/bin/env ruby

$safe_start_fd = ENV['RELIABLE_START_FD']
$safe_start_fd &&= $safe_start_fd.to_i

# ensure that everything is properly closed
(3..32).each do |fd|
  next if fd == $safe_start_fd
  # puts "closing: #{fd}"
  begin
    IO.for_fd(fd, "r").close
  rescue Errno::EBADF, Errno::EINVAL
  end
  begin
    IO.for_fd(fd, "a").close
  rescue Errno::EBADF
  end
end

#Process.setpgid(0, 0)
sleeper = fork do
  # this process ensure that we have stopped process in our
  # process group.
  #
  # This will cause whole group to be sent SIGHUP when process group
  # will become orphaned. That will happen when our main process or
  # it's parent will die.
  Process.kill("STOP", Process.pid)
end

Process.kill("STOP", sleeper)

if $safe_start_fd
  $safe_start_fd = IO.for_fd($safe_start_fd, 'r')
  exit unless $safe_start_fd.read(1) == 'O'
end

system(*ARGV)
