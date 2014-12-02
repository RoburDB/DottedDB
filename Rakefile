require 'fileutils'

#RIAK_VERSION      = "2.0.2"
#RIAK_DOWNLOAD_URL = "http://s3.amazonaws.com/downloads.basho.com/riak/2.0/#{RIAK_VERSION}/osx/10.8/riak-#{RIAK_VERSION}-OSX-x86_64.tar.gz"
NUM_NODES = 4
NUM_NODES_STR = "4"
#RING_SIZE = 16
BACKEND = 'leveldb' #options: bitcask, leveldb, memory.

task :default => :help

task :help do
  sh %{rake -T}
end

desc "install, start and join dotted_db nodes"
task :dev => [:build, :start, :join, :converge]

desc "compile the dotted_db source"
task :compile do
  sh "make all" rescue "make error"
end

desc "make the dev dotted_db folders"
task :build => :clear do
  sh "make stagedevrel" rescue "build dev error"
end

desc "start all dotted_db nodes"
task :start do
  (1..NUM_NODES).each do |n|
    sh %{dev/dev#{n}/bin/dotted_db start}
  end
  puts "========================================"
  puts "Dotted Dev Cluster started"
  puts "========================================"
end

desc "join dotted_db nodes (only needed once)"
task :join do
  (2..NUM_NODES).each do |n|
      sh %{dev/dev#{n}/bin/dotted_db-admin cluster join dotted_db1@127.0.0.1} rescue "already joined"
  end
  sh %{dev/dev1/bin/dotted_db-admin cluster plan}
  sh %{dev/dev1/bin/dotted_db-admin cluster commit}
end

desc "waits for cluster vnode converge to stabilize"
task :converge do
  puts "waiting for cluster vnode reshuffling to converge"
  $stdout.sync = true
  res2 = `dev/dev1/bin/dotted_db-admin member-status | grep "\ \-\-" | wc -l`
  while (res2.strip != NUM_NODES_STR)
    print "."
    sleep(1)
    res2 = `dev/dev1/bin/dotted_db-admin member-status | grep "\ \-\-" | wc -l`
  end
  sh %{dev/dev1/bin/dotted_db-admin member-status}
  puts "READY SET GO!"
end

desc "dotted_db-admin member-status"
task :member_status do
  sh %{dev/dev1/bin/dotted_db-admin member-status}
end

desc "stop all dotted_db nodes"
task :stop do
  (1..NUM_NODES).each do |n|
    sh %{dev/dev#{n}/bin/dotted_db stop} rescue "not running"
  end
  puts "========================================"
  puts "Dotted Dev Cluster stopped"
  puts "========================================"
end

desc "restart all dotted_db nodes"
task :restart => [:stop, :start]

desc "clear data from all dotted_db nodes"
  task :clear => :stop do
    (1..NUM_NODES).each do |n|
      sh %{rm -rf dev/dev#{n}}
  end
end

desc "ping all dotted_db nodes"
task :ping do
  (1..NUM_NODES).each do |n|
      sh %{dev/dev#{n}/bin/dotted_db ping}
  end
end

desc "dotted_db-admin test"
task :test do
  (1..NUM_NODES).each do |n|
    sh %{dev/dev#{n}/bin/dotted_db-admin test}
  end
end

desc "dotted_db-admin status"
task :status do
  sh %{dev/dev1/bin/dotted_db-admin  status}
end

desc "dotted_db-admin ring-status"
task :ring_status do
  sh %{dev/dev1/bin/dotted_db-admin  ring-status}
end


# task :copy_riak do
#   (1..NUM_NODES).each do |n|
#     system %{cp -nr riak-#{RIAK_VERSION}/ riak#{n}}
#    system %(sed -i '' 's/riak@127.0.0.1/riak#{n}@127.0.0.1/' riak#{n}/etc/riak.conf)
#    system %(sed -i '' 's/127.0.0.1:8098/127.0.0.1:1#{n}098/' riak#{n}/etc/riak.conf)
#    system %(sed -i '' 's/127.0.0.1:8087/127.0.0.1:1#{n}087/' riak#{n}/etc/riak.conf)
#    system %(echo 'riak_control = on' >> riak#{n}/etc/riak.conf)
#    system %(echo 'handoff.port = 1#{n}099' >> riak#{n}/etc/riak.conf)
#     system %(echo 'ring_size = #{RING_SIZE}' >> riak#{n}/etc/riak.conf)
#    system %(echo 'storage_backend = #{BACKEND}' >> riak#{n}/etc/riak.conf)
#   end
# end