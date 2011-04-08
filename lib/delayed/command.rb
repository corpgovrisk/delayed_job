require 'rubygems'
require 'daemons'
require 'optparse'

module Delayed
  class Command
    attr_accessor :worker_count
    
    def initialize(args)
      @files_to_reopen = []
      @options = {
        :quiet => true,
        :pid_dir => "#{Rails.root}/tmp/pids"
      }
      
      @worker_count = 1
      @monitor = false
      
      opts = OptionParser.new do |opts|
        opts.banner = "Usage: #{File.basename($0)} start|stop|restart|run [options]"

        opts.on('-h', '--help', 'Show this message') do
          puts opts
          exit 1
        end
        opts.on('-e', '--environment=NAME', 'Specifies the environment to run this delayed jobs under (test/development/production).') do |e|
          STDERR.puts "The -e/--environment option has been deprecated and has no effect. Use RAILS_ENV and see http://github.com/collectiveidea/delayed_job/issues/#issue/7"
        end
        opts.on('--min-priority N', 'Minimum priority of jobs to run.') do |n|
          @options[:min_priority] = n
        end
        opts.on('--max-priority N', 'Maximum priority of jobs to run.') do |n|
          @options[:max_priority] = n
        end
        opts.on('-n', '--number_of_workers=workers', "Number of unique workers to spawn") do |worker_count|
          @worker_count = worker_count.to_i rescue 1
        end
        opts.on('--pid-dir=DIR', 'Specifies an alternate directory in which to store the process ids.') do |dir|
          @options[:pid_dir] = dir
        end
        opts.on('-i', '--identifier=n', 'A numeric identifier for the worker.') do |n|
          @options[:identifier] = n
        end
        opts.on('-m', '--monitor', 'Start monitor process.') do
          @monitor = true
        end
        opts.on('--sleep-delay N', "Amount of time to sleep when no jobs are found") do |n|
          @options[:sleep_delay] = n
        end
        opts.on('-p', '--prefix NAME', "String to be prefixed to worker process names") do |prefix|
          @options[:prefix] = prefix
        end
        opts.on('--file=FILE', "File to be run in processes in addition to normal delayed_job behaviour") do |file|
          @options[:file] = file
        end
        opts.on('-fn', '--number_of_workers_for_file=workers', "Number of unique workers to have file included") do |worker_count|
          @options[:file_worker_count] = worker_count.to_i rescue 1
        end
      end
      @args = opts.parse!(args)
    end
  
    def daemonize
      Delayed::Worker.backend.before_fork

      ObjectSpace.each_object(File) do |file|
        @files_to_reopen << file unless file.closed?
      end
      
      dir = @options[:pid_dir]
      Dir.mkdir(dir) unless File.exists?(dir)
      
      if @worker_count > 1 && @options[:identifier]
        raise ArgumentError, 'Cannot specify both --number-of-workers and --identifier'
      elsif @worker_count == 1 && @options[:identifier]
        process_name = "delayed_job.#{@options[:identifier]}"
        run_process(process_name, dir)
      else
        worker_count.times do |worker_index|
          process_name = worker_count == 1 ? "delayed_job" : "delayed_job.#{worker_index}"
          run_process(process_name, dir, worker_index)
        end
      end
    end
    
    def run_process(process_name, dir, worker_index = 0)
      Daemons.run_proc(process_name, :dir => dir, :dir_mode => :normal, :monitor => @monitor, :ARGV => @args) do |*args|
        $0 = File.join(@options[:prefix], process_name) if @options[:prefix]
        run process_name, worker_index
      end
    end
    
    def run(worker_name = nil, worker_index = 0)
      Dir.chdir(Rails.root)

      
      # Re-open file handles
      @files_to_reopen.each do |file|
        begin
          file.reopen file.path, "a+"
          file.sync = true
        rescue ::Exception
        end
      end
      
      Delayed::Worker.logger = Logger.new(File.join(Rails.root, 'log', 'delayed_job.log'))
      Delayed::Worker.backend.after_fork

      if !@options[:file_worker_count].nil? && worker_index <= @options[:file_worker_count] 
        Rails.logger.debug "#{Time.now.strftime('%FT%T%z')}: Attempting to load file: #{@options[:file]} in worker: #{worker_index}"
        begin 
          require @options[:file]
        rescue => e
          Rails.logger.debug "#{Time.now.strftime('%FT%T%z')}: #{e.message}"
        end
      end
      
      worker = Delayed::Worker.new(@options)
      worker.name_prefix = "#{worker_name} "
      worker.start
    rescue => e
      Rails.logger.fatal e
      STDERR.puts e.message
      exit 1
    end
    
  end
end
