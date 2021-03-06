require 'rails'
require 'rails/railtie'
require 'action_controller/railtie'
require 'active_support/core_ext/module/remove_method'
require 'sprockets'
require 'sprockets/rails/context'
require 'sprockets/rails/helper'
require 'sprockets/rails/version'

module Rails
  class Application
    # Hack: We need to remove Rails' built in config.assets so we can
    # do our own thing.
    class Configuration
      remove_possible_method :assets
    end

    # Undefine Rails' assets method before redefining it, to avoid warnings.
    remove_possible_method :assets
    remove_possible_method :assets=

    # Returns Sprockets::Environment for app config.
    def assets
      @assets ||= Sprockets::Environment.new(root.to_s) do |env|
        env.version = ::Rails.env
        env.cache = Sprockets::Cache::FileStore.new("#{root}/tmp/cache")

        env.context_class.class_eval do
          include ::Sprockets::Rails::Context
        end
      end
    end
    attr_writer :assets

    # Returns Sprockets::Manifest for app config.
    attr_accessor :assets_manifest
  end
end

module Sprockets
  class Railtie < ::Rails::Railtie
    LOOSE_APP_ASSETS = lambda do |filename, path|
      path.start_with?(::Rails.root.join("app/assets").to_s) &&
        !%w(.js .css).include?(File.extname(logical_path))
    end

    class OrderedOptions < ActiveSupport::OrderedOptions
      def configure(&block)
        self._blocks << block
      end
    end

    config.assets = OrderedOptions.new
    config.assets._blocks    = []
    config.assets.paths      = []
    config.assets.prefix     = "/assets"
    config.assets.manifest   = nil
    config.assets.precompile = [LOOSE_APP_ASSETS, /(?:\/|\\|\A)application\.(css|js)$/]
    config.assets.version    = ""
    config.assets.debug      = false
    config.assets.compile    = true
    config.assets.digest     = false

    rake_tasks do |app|
      require 'sprockets/rails/task'
      Sprockets::Rails::Task.new(app)
    end

    config.after_initialize do |app|
      config = app.config

      # Configuration options that should invalidate
      # the Sprockets cache when changed.
      app.assets.version = [
        ::Rails.env,
        app.assets.version,
        config.assets.version,
        config.action_controller.relative_url_root,
        (config.action_controller.asset_host unless config.action_controller.asset_host.respond_to?(:call)),
        Sprockets::Rails::VERSION
      ].compact.join('-')

      # Copy config.assets.paths to Sprockets
      config.assets.paths.each do |path|
        app.assets.append_path path
      end

      app.assets.js_compressor  = config.assets.js_compressor
      app.assets.css_compressor = config.assets.css_compressor

      # Run app.assets.configure blocks
      config.assets._blocks.each do |block|
        block.call app.assets
      end

      # No more configuration changes at this point.
      # With cache classes on, Sprockets won't check the FS when files
      # change. Preferable in production when the FS only changes on
      # deploys when the app restarts.
      if config.cache_classes
        app.assets = app.assets.cached
      end

      manifest_assets_path = File.join(config.paths['public'].first, config.assets.prefix)
      if config.assets.compile
        app.assets_manifest = Sprockets::Manifest.new(app.assets, manifest_assets_path, config.assets.manifest)
      else
        app.assets_manifest = Sprockets::Manifest.new(manifest_assets_path, config.assets.manifest)
      end

      ActiveSupport.on_load(:action_view) do
        include Sprockets::Rails::Helper

        # Copy relevant config to AV context
        self.debug_assets      = config.assets.debug
        self.digest_assets     = config.assets.digest
        self.assets_prefix     = config.assets.prefix
        self.assets_precompile = config.assets.precompile

        # Copy over to Sprockets as well
        context = app.assets.context_class
        context.assets_prefix = config.assets.prefix
        context.digest_assets = config.assets.digest
        context.config        = config.action_controller

        self.assets_environment = app.assets if config.assets.compile
        self.assets_manifest = app.assets_manifest
      end

      if config.assets.compile
        app.routes.prepend do
          mount app.assets => config.assets.prefix
        end
      end
    end
  end
end
