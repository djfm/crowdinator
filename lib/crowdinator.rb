require 'json'
require 'uri'
require 'rest-client'
require 'gmail'
require 'shellwords'
require 'headless'

require_relative 'helper'
require_relative 'prestashop'

module Crowdinator
	def self.config
		return @config if @config

		config = JSON.parse File.read(path 'config.json')

		unless config['www_root']
			log "Config must include the 'www_root' key!"
		end

		unless File.exists? root=config['www_root']
			log_system('mkdir', '--parents', root)
		end

		@config = config
	end

	def self.get_shop front_office_url, filesystem_path, version
		PrestaShop.new({
			front_office_url: front_office_url,
			back_office_url: URI.join(front_office_url, 'admin-dev/'),
			installer_url: URI.join(front_office_url, 'install-dev/'),
			admin_email: 'pub@prestashop.com',
			admin_password: '123456789',
			database_name: "crowdinator_#{version}",
			database_user: config['mysql_user'],
			database_password: config['mysql_password'],
			filesystem_path: filesystem_path,
			version: version
		})
	end

	def self.install version, options={}
		shop_root = path 'versions', version, 'shop'
		unless File.directory? shop_root
			raise "Could not find shop files in: #{shop_root}"
		end
		target = File.join config['www_root'], version

		if File.exists? target
			log_system 'cp', path('etc', 'autokill.php'), target
			kill_url = URI.join(config['www_base'], version + '/autokill.php').to_s
			log "Calling autokill url: #{kill_url}"
			RestClient.get kill_url
		end

		pwd = Dir.pwd
		Dir.chdir shop_root
		need_pull = `git remote` != ""
		Dir.chdir pwd

		unless options[:skip_pull] or !need_pull
			if log_system('git', 'status', :chdir => shop_root)
				if log_system('git', 'pull', :chdir => shop_root)
					unless log_system('git', 'submodule', 'foreach', 'git', 'pull', :chdir => shop_root)
						raise "Could not run pull for submodules in: #{shop_root}"
					end
				else
					raise "Could not pull in: #{shop_root}"
				end
			end
		end

		unless log_system('cp', '-R', shop_root, target)
			raise "Could not copy files from '#{shop_root}' to '#{target}'"
		end

		unless log_system('chmod', '777', '-R', target)
			raise "Could not copy chmod 777 -R '#{target}'"
		end

		base = URI.join config['www_base'], version + '/'

		shop = get_shop base, target, version

		shop.drop_database
		shop.install language: 'en', country: 'us'

		shop.login_to_back_office
		shop.update_all_modules

		return shop
	end

	def self.regenerate_translations
		url = "http://api.crowdin.net/api/project/#{config['crowdin_project']}/export?key=#{config['crowdin_api_key']}&json"
		begin
			reply = `curl #{Shellwords.shellescape url}`
			data = JSON.parse reply
			if data["success"]
				return data["success"]["status"]
			else
				raise "Could not regenerate the translations for some reason."
			end
		rescue
			log "Could not regenerate translations, reply was:\n#{reply}"
		end
	end

	def self.test_packs shop, version
		valid_packs =  []

		backup_folder = path 'versions', version, 'archive', Time.now.to_s
		unless log_system 'mkdir', '--parents', backup_folder
			raise "Could not create folder: #{backup_folder}"
		end

		Dir.glob path('versions', version, 'packs', '*') do |pack|
			ok = shop.check_translation_pack pack
			if ok
				valid_packs << pack
				unless log_system 'cp', pack, backup_folder
					raise "Could not backup '#{pack}' to '#{backup_folder}'"
				end
				log "Pack '#{pack}' looks alright."
			else
				unless log_system 'rm', pack
					raise "Aborting, could not delete bad pack '#{pack}'."
				end
				log "Ouch! Pack '#{pack}' is dead."
			end
		end

		return valid_packs
	end

	def self.recordError str
		(@errors ||= []) << str
	end

	def self.errors
		@errors
	end

	def self.publish_pack version, language

		if language == 'tr'
			log "Skipped Turkish because ZERO translations"
			return false
		end

		source = path 'versions', version, 'packs', "#{language}.gzip"
		unless File.exists? source
			raise "Can't find file: #{source}"
		end
		conf_path = path 'versions', version, 'config.json'
		unless File.exists? conf_path
			raise "Missing config file: #{conf_path}"
		end
		conf = JSON.parse File.read(conf_path)
		version_header = conf['version_header']
		unless version_header
			raise "Missing version_header key in '#{conf_path}'"
		end

		home_url, cookies = RestClient.post config['publisher_url'],
			'email' => config['publisher_email'],
			'passwd' => config['publisher_password'],
			'controller' => 'AdminLogin',
			'submitLogin' =>'1' do |response|
			case response.code
			when 302
				[response.headers[:location], response.cookies]
			else
				raise "Unexpected response while loggin in to '#{config['publisher_url']}'"
			end
		end

		query = RestClient.get(URI.join(config['publisher_url'], home_url).to_s, {:cookies => cookies})
								.to_s[/(["'])(.*?\?controller=AdminTranslations\b.*?)\1/, 2]

		admin_translations_url = URI.join(config['publisher_url'], query).to_s

		data = {
			'file' => File.new(source, 'rb'),
			'submitImport' => 'Import',
			'ps_version_header' => version_header,
			'ExportDirectly' => 'on'
		}

		RestClient.post admin_translations_url, data, {:cookies => cookies} do |response|
			case response.code
			when 302
				if response.headers[:location][/\bconf=15\b/].nil?
					recordError "Failed to publish pack: #{source}"
					return false
				else
					return true
				end
			else
				recordError "Failed to publish pack: #{source}"
				return false
			end
		end
	end

	def self.publish_all_packs version
		languages = config['versions'][version]["publish"] rescue nil
		exclude   = config['versions'][version]["exclude"] rescue []

		if languages == "*"
			languages = Dir.entries(path('versions', version, 'packs')).map do |name|
				name[/^([a-z]{2})\.gzip$/,1]
			end.reject &:nil?
		end

		languages = languages.reject do |language|
			exclude.include? language
		end

		if languages
			languages.each do |language|
				begin
					if publish_pack version, language
						log "Successfully published #{language} for #{version}"
					else
						log "Could not publish #{language} for #{version}"
					end
				rescue => e
					log "Exception thrown while publishing #{language} for #{version}, continuing anyway..."
				end
			end
		end

		return languages
	end

	def self.perform version, actions, options={}
		shop = install version, options
		shop.add_and_configure_necessary_modules version: version

		actions.each do |action|
			case action
			when :publish_strings
				log "Publishing strings..."
				shop.translatools_publish_strings
				log "Done publishing strings!"
			when :build_packs
				log "Building packs..."
				unless log_system 'rm', '-Rf', path('versions', version, 'packs', '*')
					raise "Could not delete old packs."
				end
				shop.translatools_build_packs path('versions', version, 'packs', 'all_packs.tar.gz')
				packs = test_packs shop, version
				log "Done building packs!"
			when :publish_all_packs
				log "Publishing packs..."
				publish_all_packs version
				log "Done publishing packs!"
			end
		end
	end

	def self.work_for_me options={}

		lockfile = File.open(path('running.lock'), 'w');
		unless lockfile.flock(File::LOCK_EX | File::LOCK_NB);
			feedback :error, "Not publishing translations, already in progress."
			return
		end

		action = lambda do
			begin
				unless options[:skip_regenerate]
					log "Regenerating translations..."
					regenerate_translations
					log "Done regenerating the translations!"
				else
					log "Skipping regeneration of the translations as asked"
				end
				config['versions'].sort {|a, b| Gem::Version.new(b[0].dup) <=> Gem::Version.new(a[0].dup)}.each do |version, data|
					if !options[:version] or options[:version] == version
						log "Now processing version #{version}..."
						perform version, data['actions'].map(&:to_sym), options
					else
						puts "Skipping #{version}, only interested in #{options[:version]}"
					end
				end
				feedback :success, "Successfully published translations!"
			rescue => e
				error = e.to_s
				if e.public_methods.include? :backtrace
					error += "\n#{e.backtrace.map do |line| "\t#{line}" end.join("\n")}"
				end
				log "FATAL: #{error}"
				feedback :error, "Failed to publish translations.", error
			end
		end

		if options[:headless]
			Headless.ly do
				action.call
			end
		else
			action.call
		end

		lockfile.flock(File::LOCK_UN)
	end

	def self.feedback status, title, focus=nil
		gmail = Gmail.connect! config['gmail_username'], config['gmail_password']
		content = [focus.to_s, logger.to_s].join "\n\n\n"

		config['send_feedback_to'].each do |recipient|
			gmail.deliver do
				to recipient
				subject title
				text_part do
					body content
				end
			end
		end
	end
end
