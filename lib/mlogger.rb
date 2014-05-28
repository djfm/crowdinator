module Crowdinator
	class MLogger
		def initialize path
			@path = path
			@file = File.new @path, 'w'
			fd = spawn 'tail', '-f', @path
			at_exit do
				Process.kill :SIGINT, fd
			end
		end

		def fileno
			@file.fileno
		end

		def log str, options={}
			if options[:raw]
				@file.puts str
			else
				@file.puts "[#{Time.now}] #{str}"
			end
			@file.fsync
		end

		def to_s
			File.read @path
		end
	end
end
