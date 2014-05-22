require 'prestashop-automation'

module Crowdinator
	class PrestaShop < PrestaShopAutomation::PrestaShop
		def add_necessary_modules
			add_module_from_repo 'https://github.com/djfm/emailgenerator'
			add_module_from_repo 'https://github.com/djfm/translatools', 'development'
			install_module 'emailgenerator'
			install_module 'translatools'
			if has_selector? '#modules-are-missing'
				click '#modules-are-missing'
			end
			goto_module_configuration 'translatools'
			fill_in 'CROWDIN_PROJECT_IDENTIFIER', with: Crowdinator.config['crowdin_project']
			fill_in 'CROWDIN_PROJECT_API_KEY', with: Crowdinator.config['crowdin_api_key']
		end
	end
end
