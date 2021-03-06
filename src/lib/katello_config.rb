#
# Copyright 2012 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.

require 'yaml'
require 'erb'

path = File.expand_path(File.dirname(__FILE__))
$LOAD_PATH << path unless $LOAD_PATH.include? path
require 'app_config'
require 'util/password'

module Katello


  # Katello::Configuration module contains all necessary code for Katello configuration.
  # Configuration is not dependent on any gem which allows loading configuration very early
  # (even before Rails). Therefore this configuration can be used anywhere
  # (Gemfile, boot scripts, stand-alone)
  #
  # Configuration access points are methods {Katello.config} and {Katello.early_config}, see method documentation.
  #
  # Configuration is represented with tree-like-structure defined with Configuration::Node. Node has
  # minimal Hash-like interface. Node is more strict than Hash. Differences:
  # * If undefined key is accessed an error NoKey is raised (keys with nil values has to be
  #   defined explicitly).
  # * Keys can be accessed by methods. `config.host` is equivalent to `config[:host]`
  # * All keys has to be Symbols, otherwise you get an ArgumentError
  #
  # AppConfig will work for now, but warning is printed to `$stderr`.
  #
  # Some examples
  #
  #     !!!txt
  #     # create by a Hash which is converted to Node instance
  #     irb> n = Katello::Configuration::Node.new 'a' => nil
  #     => #<Katello::Configuration::Node:0x10e27b618 @data={:a=>nil}>
  #
  #     # assign a value, also converted
  #     irb> n[:a] = {'a' => 12}
  #     => {:a=>12}
  #     irb> n
  #     => #<Katello::Configuration::Node:0x10e2cd2b0 @data=
  #         {:a=>#<Katello::Configuration::Node:0x10e2bcb40 @data={:a=>12}>}>
  #
  #     # accessing a key
  #     irb> n['a']
  #     ArgumentError: "a" should be a Symbol
  #     irb> n[:a]
  #     => #<Katello::Configuration::Node:0x10e2bcb40 @data={:a=>12}>
  #     irb> n[:not]
  #     Katello::Configuration::Node::NoKey:  missing key 'not' in configuration
  #
  #     # supports deep_merge and #to_hash
  #     irb> n.deep_merge!('a' => {:b => 34})
  #     => #<Katello::Configuration::Node:0x10e2cd2b0 @data=
  #         {:a=>#<Katello::Configuration::Node:0x10e2a64d0 @data={:a=>12, :b=>34}>}>
  #     irb> n.to_hash
  #     => {:a=>{:a=>12, :b=>34}}
  #
  module Configuration

    # Hash like container for configuration
    # @example allows access by method
    #     Config.new('a' => {:b => 2}).a.b # => 2
    class Node
      class NoKey < StandardError
        def initialize(message = nil)
          #noinspection RubyArgCount
          super(" missing key '#{message}' in configuration")
        end
      end

      def initialize(data = { })
        @data = convert_hash data
      end

      include Enumerable

      def each(&block)
        @data.each &block
      end

      # get configuration for `key`
      # @param [Symbol] key
      # @raise [NoKye] when key is missing
      def [](key)
        raise ArgumentError, "#{key.inspect} should be a Symbol" unless Symbol === key
        if has_key? key
          @data[key].is_a?(Proc) ? @data[key].call : @data[key]
        else
          raise NoKey, key.to_s
        end
      end

      # converts `value` to Config
      # @see #convert
      def []=(key, value)
        @data[key.to_sym] = convert value
      end

      def has_key?(key)
        @data.has_key? key
      end

      # @example does node contain value at `node[:key1][:key2]`
      #    node.present? :key1, :key2
      def present?(*keys)
        key, rest = keys.first, keys[1..-1]
        raise ArgumentError, 'supply at least one key' unless key
        has_key? key and self[key] and if rest.empty?
                                         true
                                       elsif Node === self[key]
                                         self[key].present?(*rest)
                                       else
                                         false
                                       end
      end

      # allows access keys by method call
      # @raise [NoKye] when `key` is missing
      def method_missing(method, *args, &block)
        if has_key?(method)
          self[method]
        else
          begin
            super
          rescue NoMethodError => e
            raise NoKey, method.to_s
          end
        end
      end

      # does not supports Hashes in Arrays
      def deep_merge!(hash_or_config)
        return self if hash_or_config.nil?
        other_config = convert hash_or_config
        other_config.each do |key, other_value|
          value     = has_key?(key) && self[key]
          self[key] = if Node === value && Node === other_value
                        value.deep_merge!(other_value)
                      elsif Node === value && other_value.nil?
                        self[key]
                      else
                        other_value
                      end
        end
        self
      end

      def to_hash
        @data.inject({ }) do |hash, (k, v)|
          hash.update k => (Node === v ? v.to_hash : v)
        end
      end

      private

      # converts config like deep structure by finding Hashes deeply and converting them to Config
      def convert(obj)
        case obj
        when Node
          obj
        when Hash
          Node.new convert_hash obj
        when Array
          obj.map { |o| convert o }
        else
          obj
        end
      end

      # converts Hash by symbolizing keys and allowing only symbols as keys
      def convert_hash(hash)
        raise ArgumentError, "#{hash.inspect} is not a Hash" unless Hash === hash

        hash.keys.each do |key|
          hash[(key.to_sym rescue key) || key] = convert hash.delete(key)
        end

        hash.keys.all? do |k|
          Symbol === k or raise ArgumentError, "keys must be Symbols, #{k.inspect} is not"
        end
        hash
      end
    end

    # defines small dsl for validating configuration
    class Validator
      attr_reader :config, :environment, :path

      # @param [Node] config
      # @param [nil, Symbol] environment use nil for early or Symbol for environment
      # @yield block with validations
      def initialize(config, environment, path = [], &validations)
        @config, @environment, @path = config, environment, path
        instance_eval &validations
      end

      private

      def early?
        !environment
      end

      # validate sub key
      # @yield block with validations
      def validate(key, &block)
        Validator.new config[key] || Node.new, environment, (self.path + [key]), &block
      end

      def are_booleans(*keys)
        keys.each { |key| is_boolean key }
      end

      def is_boolean(key)
        has_values key, [true, false]
      end

      def has_values(key, values, options = { })
        values << nil if options[:allow_nil]
        return true if values.include?(config[key])
        raise ArgumentError, error_format(key, "should be one of #{values.inspect}, but was #{config[key].inspect}")
      end

      def has_keys(*keys)
        keys.each { |key| has_key key }
      end

      def has_key(key)
        unless config.has_key? key.to_sym
          raise error_format(key.to_sym, 'is required')
        end
      end

      private

      def error_format(key, message)
        key_path = (path + [key]).join('.')
        env      = environment ? "'#{environment}' environment" : 'early configuration'
        "Key: '#{key_path}' in #{env} #{message}"
      end

      def is_not_empty(key)
        if config[key].nil? || config[key].empty?
          raise error_format(key.to_sym, "must not be empty")
        end
      end
    end

    # processes configuration loading from config_files
    class LoaderImpl
      attr_reader :config_file_paths, :validation

      def initialize(options = { })
        @config_file_paths = options[:config_file_paths] || raise(ArgumentError)
        @validation        = options[:validation] || raise(ArgumentError)
      end

      # raw config data form katello.yml represented with Node
      def config_data
        @config_data ||= Node.new(
            YAML::load(ERB.new(File.read(config_file_path)).result(Object.new.send(:binding)))).tap do |config|
          config.each do |k, env_config|
            decrypt_password! env_config.database if env_config && env_config.present?(:database)
          end
        end
      end

      # access point for Katello configuration
      def config
        @config ||= load(environment)
      end

      # Configuration without environment applied, use in early stages (before Rails are loaded)
      # like Gemfile and other scripts
      def early_config
        @early_config ||= load
      end

      # @return [Hash{String => Hash}] database configurations
      def database_configs
        @database_configs ||= begin
          %w(production development test).inject({ }) do |hash, environment|
            common = config_data.common.database.to_hash
            if config_data.present?(environment.to_sym, :database)
              hash.update(
                  environment =>
                      common.merge(config_data[environment.to_sym].database.to_hash).stringify_keys)
            else
              hash
            end
          end
        end
      end

      private

      def load(environment = nil)
        Node.new.tap do |c|
          load_config_file c, environment
          post_process c
          validate c, environment
        end
      end

      def environment
        Rails.env.to_sym rescue raise 'Rails.env is not accessible, try to use #early_config instead'
      end

      def load_config_file(config, environment = nil)
        config.deep_merge! config_data[:common]
        config.deep_merge! config_data[environment] if environment
      end

      def post_process config
        config[:katello?] = lambda { config.app_mode == 'katello' }
        config[:headpin?] = lambda { config.app_mode == 'headpin' }
        config[:app_name] ||= config.katello? ? 'Katello' : 'Headpin'

        config[:use_cp] = true if config[:use_cp].nil?
        config[:use_pulp] = config.katello? if config[:use_pulp].nil?
        config[:use_foreman] = config.katello? if config[:use_foreman].nil?
        config[:use_elasticsearch] = config.katello? if config[:use_elasticsearch].nil?

        config[:email_reply_address] = config[:email_reply_address] ?
            config[:email_reply_address] : "no-reply@"+config[:host]

        load_version config
      end

      def decrypt_password!(database_config)
        database_config[:password] = Password.decrypt database_config.password if database_config.present?(:password)
      end

      def load_version(config)
        package = config.katello? ? 'katello-common' : 'katello-headpin'
        version = `rpm -q #{package} --queryformat '%{VERSION}-%{RELEASE}' 2>&1`
        if $? != 0
          hash    = `git rev-parse --short HEAD 2>/dev/null`
          version = $? == 0 ? "git hash (#{hash.chop})" : "Unknown"
        end

        config[:katello_version] = version
      end

      def validate(config, environment)
        Validator.new config, environment, &validation
      end

      def config_file_path
        @config_file_path ||= config_file_paths.find { |path| File.exist? path } or
            raise "no config file found, candidates: #{config_file_paths.join ' '}"
      end
    end

    root = File.expand_path(File.join(File.dirname(__FILE__), '..'))

    VALIDATION = lambda do |*_|
      has_keys *%w( app_name candlepin notification debug_pulp_proxy debug_rest available_locales
                    use_cp simple_search_tokens database debug_cp_proxy headpin? host ldap_roles
                    cloud_forms use_pulp cdn_proxy use_ssl warden katello? url_prefix foreman
                    search use_foreman password_reset_expiration redhat_repository_url port
                    elastic_url rest_client_timeout elastic_index allow_roles_logging
                    katello_version pulp tire_log log_level log_level_sql email_reply_address
                    embed_yard_documentation)

      has_values :app_mode, %w(katello headpin)
      has_values :url_prefix, %w(/headpin /sam /cfse /katello)

      log_levels = %w(debug info warn error fatal)
      has_values :log_level, log_levels
      has_values :log_level_sql, log_levels

      unless config.katello?
        is_not_empty :thumbslug_url
      end

      are_booleans :use_cp, :use_foreman, :use_pulp, :use_elasticsearch, :use_ssl, :ldap_roles, :debug_rest,
                   :debug_cp_proxy, :debug_pulp_proxy, :logical_insight

      if !early? && environment != :build
        validate :database do
          has_keys *%w(adapter host encoding username password database)
        end
      end
    end

    Loader = LoaderImpl.new(
        :config_file_paths => %W(#{root}/config/katello.yml /etc/katello/katello.yml),
        :validation        => VALIDATION)
  end


  # @see Configuration::LoaderImpl#config
  def self.config
    Configuration::Loader.config
  end

  # @see Configuration::LoaderImpl#early_config
  def self.early_config
    Configuration::Loader.early_config
  end

  # @see Configuration::LoaderImpl#database_configs
  def self.database_configs
    Configuration::Loader.database_configs
  end
end


