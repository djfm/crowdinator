require 'prestashop-automation'

module Crowdinator
	class PrestaShop < PrestaShopAutomation::PrestaShop
		def add_and_configure_necessary_modules options
			add_module_from_repo 'https://github.com/djfm/emailgenerator'
			add_module_from_repo 'https://github.com/djfm/translatools', 'development'
			install_module 'emailgenerator'
			install_module 'translatools'
			if has_selector? '#modules-are-missing'
				click '#modules-are-missing'
			end

			goto_module_configuration 'translatools'
			expect_not_to have_selector '#modules-are-missing'

			fill_in 'CROWDIN_PROJECT_IDENTIFIER', with: Crowdinator.config['crowdin_project']
			fill_in 'CROWDIN_PROJECT_API_KEY', with: Crowdinator.config['crowdin_api_key']
			fill_in 'CROWDIN_FORCED_VERSION', with: options[:version]
			click '#save-settings'
		end

		def translatools_publish_strings
			goto_module_configuration 'translatools'
			evaluate_script 'exportSourcesToCrowdin(true)'
			wait_until timeout: 1800 do
				has_selector? '#sources-successfully-exported'
			end
		end
	end
end
