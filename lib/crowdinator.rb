require 'json'
require 'uri'

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
		shop = PrestaShop.new({
			front_office_url: base,
			back_office_url: URI.join(base, 'admin-dev/'),
			installer_url: URI.join(base, 'install-dev/'),
			admin_email: 'pub@prestashop.com',
			admin_password: '123456789',
			database_name: "crowdinator_#{version}",
			database_user: config['mysql_user'],
			database_password: config['mysql_password'],
			filesystem_path: target,
			version: version
		})

		shop.drop_database
		shop.install language: 'en', country: 'us'

		shop.login_to_back_office
		shop.update_all_modules

		return shop
	end

	def self.perform version, actions, options={}
		shop = install version, options
		shop.add_and_configure_necessary_modules version: version

		actions.each do |action|
			case action
			when :publish_strings
				shop.translatools_publish_strings
			end
		end
	end
end
