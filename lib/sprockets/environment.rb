require 'hike'
require 'logger'
require 'thread'
require 'tilt'

module Sprockets
  class Environment
    DEFAULT_ENGINE_EXTENSIONS = %w( .coffee .erb .less .sass .scss .str )
    CONCATENATABLE_EXTENSIONS = %w( .css .js )

    @template_mappings = {}

    def self.register(ext, klass)
      ext = ext.to_s.sub(/^\./, '').downcase
      @template_mappings[ext] = klass
    end

    def self.lookup_engine(ext)
      ext = ext.to_s.sub(/^\./, '').downcase
      @template_mappings[ext] || Tilt[ext]
    end

    register 'jst', JavascriptTemplate

    attr_accessor :logger

    def initialize(root = ".", store = nil)
      @trail = Hike::Trail.new(root)
      engine_extensions.replace(DEFAULT_ENGINE_EXTENSIONS + CONCATENATABLE_EXTENSIONS)

      @logger = Logger.new($stderr)
      @logger.level = Logger::FATAL

      @cache = {}
      @store = Storage.new(store)
      @lock  = nil
    end

    def multithread
      @lock ? true : false
    end

    def multithread=(val)
      @lock = val ? Mutex.new : nil
    end

    def root
      @trail.root
    end

    def paths
      @trail.paths
    end

    def engine_extensions
      @trail.extensions
    end

    def server
      @server ||= Server.new(self)
    end

    def resolve(logical_path, options = {})
      if block_given?
        @trail.find(logical_path, options) do |path|
          yield Pathname.new(path)
        end
      else
        resolve(logical_path, options) do |pathname|
          return pathname
        end
        raise FileNotFound, "couldn't find file '#{logical_path}'"
      end
    end

    def build_asset(logical_path)
      logger.info "[Sprockets] Building asset for #{logical_path}"

      begin
        pathname = resolve(logical_path)
      rescue FileNotFound
        nil
      else
        if concatenatable?(pathname.format_extension)
          ConcatenatedAsset.new(self, pathname)
        else
          StaticAsset.new(pathname)
        end
      end
    end

    def find_asset(logical_path, digest = nil)
      logger.debug "[Sprockets] Finding asset for #{logical_path}"

      if digest && digest != ""
        if (asset = @cache[logical_path]) && asset.digest == digest
          asset
        elsif asset = @store[digest]
          asset
        elsif (asset = find_asset(logical_path)) && asset.digest == digest
          asset
        else
          logger.error "[Sprockets] Couldn't build #{logical_path} for #{digest}"
          nil
        end
      elsif asset = find_fresh_asset(logical_path)
        asset
      elsif @lock
        @lock.synchronize do
          if asset = find_fresh_asset(logical_path)
            asset
          elsif asset = build_asset(logical_path)
            @store[asset.digest] = @cache[logical_path] = asset
          end
        end
      elsif asset = build_asset(logical_path)
        @store[asset.digest] = @cache[logical_path] = asset
      end
    end

    alias_method :[], :find_asset

    protected
      def find_fresh_asset(logical_path)
        if (asset = @cache[logical_path])
          if !asset.stale?
            asset
          else
            logger.warn "[Sprockets] Asset #{logical_path} #{asset.digest} is stale"
            nil
          end
        else
          nil
        end
      end

      def concatenatable?(format_extension)
        CONCATENATABLE_EXTENSIONS.include?(format_extension)
      end
  end
end
