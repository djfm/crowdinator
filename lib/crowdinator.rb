require 'json'
require 'uri'
require 'rest-client'

require_relative 'prestashop'

module Crowdinator
	def self.root
		File.realpath(File.join(File.dirname(__FILE__), '..'))
	end

	def self.path *relative
		File.join self.root, *relative
	end

	def self.config
		return @config if @config

		config = JSON.parse File.read(path 'config.json')

		unless config['www_root']
			puts "Config must include the 'www_root' key!"
		end

		unless File.exists? root=config['www_root']
			system('mkdir', '--parents', root)
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
			throw "Could not find shop files in: #{shop_root}"
		end
		target = File.join config['www_root'], version

		system('rm', '-Rf', target) if File.exists? target

		unless options[:no_pull]
			if system('git', 'status', :chdir => shop_root)
				if system('git', 'pull', :chdir => shop_root)
					unless system('git', 'submodule', 'foreach', 'git', 'pull', :chdir => shop_root)
						throw "Could not run pull for submodules in: #{shop_root}"
					end
				else
					throw "Could not pull in: #{shop_root}"
				end
			end
		end

		unless system('cp', '-R', shop_root, target)
			throw "Could not copy files from '#{shop_root}' to '#{target}'"
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
		response = RestClient::Request.execute :method => :get, :url => url, :timeout => 7200, :open_timeout => 10
		if response.code != 200
			throw "Could not regenerate the translations."
		else
			data = JSON.parse response.to_str
			if data["success"]
				return data["success"]["status"]
			else
				throw "Could not regenerate the translations for some reason."
			end
		end
	end

	def self.test_packs shop, version
		valid_packs =  []

		backup_folder = path 'versions', version, 'archive', Time.now.to_s
		unless system 'mkdir', '--parents', backup_folder
			throw "Could not create folder: #{backup_folder}"
		end

		Dir.glob path('versions', version, 'packs', '*') do |pack|
			ok = shop.check_translation_pack pack
			if ok
				valid_packs << pack
				unless system 'cp', pack, backup_folder
					throw "Could not backup '#{pack}' to '#{backup_folder}'"
				end
				puts "Pack '#{pack}' looks alright."
			else
				unless system 'rm', pack
					throw "Aborting, could not delete bad pack '#{pack}'."
				end
				puts "Ouch! Pack '#{pack}' is dead."
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
		source = path 'versions', version, 'packs', "#{language}.gzip"
		unless File.exists? source
			throw "Can't find file: #{source}"
		end
		conf_path = path 'versions', version, 'config.json'
		unless File.exists? conf_path
			throw "Missing config file: #{conf_path}"
		end
		conf = JSON.parse File.read(conf_path)
		version_header = conf['version_header']
		unless version_header
			throw "Missing version_header key in '#{conf_path}'"
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
				throw "Unexpected response while loggin in to '#{config['publisher_url']}'"
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

		if languages == "*"
			languages = Dir.entries(path('versions', version, 'packs')).map do |name|
				name[/^([a-z]{2})\.gzip$/,1]
			end.reject &:nil?
		end

		if languages
			languages.each do |language|
				puts "Would publish #{version} #{language}"
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
				puts "Publishing strings..."
				shop.translatools_publish_strings
				puts "Done publishing strings!"
			when :build_packs
				puts "Building packs..."
				unless system 'rm', '-Rf', path('versions', version, 'packs', '*')
					throw "Could not delete old packs."
				end
				shop.translatools_build_packs path('versions', version, 'packs', 'all_packs.tar.gz')
				packs = test_packs shop, version
				puts "Done building packs!"
			when :publish_all_packs
				puts "Publishing packs..."
				publish_all_packs version
				puts "Done publishing packs!"
			end
		end
	end

	def self.work_for_me
		puts "Regenerating translations..."
		regenerate_translations
		puts "Done regenerating the translations!"
		config['versions'].each_pair do |version, data|
			puts "Now processing version #{version}..."
			perform version, data['actions'].map(&:to_sym)
		end
	end
end
