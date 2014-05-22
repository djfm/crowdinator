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
		Dir.glob path('versions', version, 'packs', '*') do |pack|
			ok = shop.check_translation_pack pack
			if ok
				valid_packs << pack
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

	def self.perform version, actions, options={}
		shop = install version, options
		shop.add_and_configure_necessary_modules version: version

		actions.each do |action|
			case action
			when :publish_strings
				shop.translatools_publish_strings
			when :build_packs
				shop.translatools_build_packs path('versions', version, 'packs', 'all_packs.tar.gz')
				packs = test_packs shop, version
			end
		end
	end
end
