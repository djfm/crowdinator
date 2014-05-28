require_relative 'mlogger'

module Crowdinator
	def self.root
		File.realpath(File.join(File.dirname(__FILE__), '..'))
	end

	def self.path *relative
		File.join self.root, *relative
	end

	@logger = MLogger.new Crowdinator.path('log', "started at #{Time.now}")

	def self.logger
		@logger
	end

	module Logging
		def log str, options={}
			::Crowdinator.logger.log str, options
		end

		def log_system *arguments
			unless arguments.last.is_a? Hash
				arguments << {}
			end
			log "\n", :raw => true
			where = arguments[-1][:chdir] ? "(in #{arguments[-1][:chdir]})" : ''
			log "Running: #{arguments[0...-1].join ' '} #{where}"
			arguments[-1] = {out: ::Crowdinator.logger.fileno, err: ::Crowdinator.logger.fileno}.merge arguments.last
			ok = system *arguments
			log (ok ? 'Finished successfully.' : 'FAILED!')
			return ok
		end
	end

	extend Logging
end
