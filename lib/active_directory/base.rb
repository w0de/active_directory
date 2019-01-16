#-- license
#
#  Based on original code by Justin Mecham and James Hunt
#  at http://rubyforge.org/projects/activedirectory
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#++ license

require 'bindata'

module ActiveDirectory
  #
  # Create a SID from the binary string in the directory
  #
  class SID < BinData::Record
    endian :little
    uint8 :revision
    uint8 :dashes
    uint48be :nt_authority
    uint32 :nt_non_unique
    array :uuids, type: :uint32, initial_length: -> { dashes - 1 }
    def to_s
      ['S', revision, nt_authority, nt_non_unique, uuids].join('-')
    end
  end

  #
  # Base class for all Ruby/ActiveDirectory Entry Objects (like User and Group)
  #
  class Base
    #
    # A Net::LDAP::Filter object that doesn't do any filtering
    # (outside of check that the CN attribute is present.  This
    # is used internally for specifying a 'no filter' condition
    # for methods that require a filter object.
    #
    NIL_FILTER = Net::LDAP::Filter.pres('cn')

    @@ldap = nil
    @@ldap_connected = false
    @@caching = false
    @@cache = {}

    #
    # Configures the connection for the Ruby/ActiveDirectory library.
    #
    # For example:
    #
    #   ActiveDirectory::Base.setup(
    #     :host => 'domain_controller1.example.org',
    #     :port => 389,
    #     :base => 'dc=example,dc=org',
    #     :auth => {
    #	:method	=> :simple,
    #       :username => 'querying_user@example.org',
    #       :password => 'querying_users_password'
    #     }
    #   )
    #
    # This will configure Ruby/ActiveDirectory to connect to the domain
    # controller at domain_controller1.example.org, using port 389. The
    # domain's base LDAP dn is expected to be 'dc=example,dc=org', and
    # Ruby/ActiveDirectory will try to bind as the
    # querying_user@example.org user, using the supplied password.
    #
    # Currently, there can be only one active connection per
    # execution context.
    #
    # For more advanced options, refer to the Net::LDAP.new
    # documentation.
    #
    def self.setup(settings)
      @@settings = settings
      @@ldap_connected = false
      @@ldap = Net::LDAP.new(settings)
    end

    def self.error
      "#{@@ldap.get_operation_result.code}: #{@@ldap.get_operation_result.message}"
    end

    ##
    # Return the last errorcode that ldap generated
    def self.error_code
      @@ldap.get_operation_result.code
    end

    def self.operation_result
      @@ldap.get_operation_result
    end

    ##
    # Check to see if the last query produced an error
    # Note: Invalid username/password combinations will not
    # produce errors
    def self.error?
      @@ldap.nil? ? false : @@ldap.get_operation_result.code != 0
    end

    ##
    # Check to see if we are connected to the LDAP server
    # This method will try to connect, if we haven't already
    def self.connected?
      @@ldap_connected ||= @@ldap.bind unless @@ldap.nil?
      @@ldap_connected
    rescue Net::LDAP::LdapError
      raise
    end

    ##
    # Check to see if result caching is enabled
    def self.cache?
      @@caching
    end

    ##
    # Clears the cache
    def self.clear_cache
      @@cache = {}
    end

    ##
    # Enable caching for queries against the DN only
    # This is to prevent membership lookups from hitting the
    # AD unnecessarilly
    def self.enable_cache
      @@caching = true
    end

    ##
    # Disable caching
    def self.disable_cache
      @@caching = false
    end

    def self.filter # :nodoc:
      NIL_FILTER
    end

    def self.required_attributes # :nodoc:
      {}
    end

    #
    # Check to see if any entries matching the passed criteria exists.
    #
    # Filters should be passed as a hash of
    # attribute_name => expected_value, like:
    #
    #   User.exists?(
    #     :sn => 'Hunt',
    #     :givenName => 'James'
    #   )
    #
    # which will return true if one or more User entries have an
    # sn (surname) of exactly 'Hunt' and a givenName (first name)
    # of exactly 'James'.
    #
    # Partial attribute matches are available.  For instance,
    #
    #   Group.exists?(
    #     :description => 'OldGroup_*'
    #   )
    #
    # would return true if there are any Group objects in
    # Active Directory whose descriptions start with OldGroup_,
    # like OldGroup_Reporting, or OldGroup_Admins.
    #
    # Note that the * wildcard matches zero or more characters,
    # so the above query would also return true if a group named
    # 'OldGroup_' exists.
    #
    def self.exists?(filter_as_hash)
      criteria = make_filter_from_hash(filter_as_hash) & filter
      @@ldap.search(filter: criteria).!empty?
    end

    #
    # Whether or not the entry has local changes that have not yet been
    # replicated to the Active Directory server via a call to Base#save
    #
    def changed?
      !@attributes.empty?
    end

    ##
    # Makes a single filter from a given key and value
    # It will try to encode an array if there is a process for it
    # Otherwise, it will treat it as an or condition
    def self.make_filter(key, value)
      # Join arrays using OR condition
      if value.is_a? Array
        filter = ~NIL_FILTER

        value.each do |v|
          filter |= Net::LDAP::Filter.eq(key, encode_field(key, v).to_s)
        end
      else
        filter = Net::LDAP::Filter.eq(key, encode_field(key, value).to_s)
      end

      filter
    end

    def self.make_filter_from_hash(hash) # :nodoc:
      return NIL_FILTER if hash.nil? || hash.empty?

      filter = NIL_FILTER

      hash.each do |key, value|
        filter &= make_filter(key, value)
      end

      filter
    end

    def self.from_dn(dn)
      ldap_result = @@ldap.search(filter: '(objectClass=*)', base: dn)
      return nil unless ldap_result

      ad_obj = new(ldap_result[0])
      @@cache[ad_obj.dn] = ad_obj unless ad_obj.instance_of? Base
      ad_obj
    end

    def self.filter_by_regex(filters, results)
      filters.each do |k,v|
        if results.empty?
          break
        end
        results = results.select { |r| r[k] =~ v }
      end
      results
    end

    #
    # Performs a search on the Active Directory store, with similar
    # syntax to the Rails ActiveRecord#find method.
    #
    # The first argument passed should be
    # either :first or :all, to indicate that we want only one
    # (:first) or all (:all) results back from the resultant set.
    #
    # The second argument should be a hash of attribute_name =>
    # expected_value pairs.
    #
    #   User.find(:all, :sn => 'Hunt')
    #
    # would find all of the User objects in Active Directory that
    # have a surname of exactly 'Hunt'.  As with the Base.exists?
    # method, partial searches are allowed.
    #
    # This method always returns an array if the caller specifies
    # :all for the search e (first argument).  If no results
    # are found, the array will be empty.
    #
    # If you call find(:first, ...), you will either get an object
    # (a User or a Group) back, or nil, if there were no entries
    # matching your filter.
    #
    def self.find(*args)
      return false unless connected?

      scope = args[0]

      options = {
        filter: args[1].nil? ? NIL_FILTER : args[1],
        in: args[1].nil? ? '' : (args[1][:in] || '')
      }

      # some folks are commenting this out as a fix (FIXME?) but I recieve no
      # errors (yet)
      # options[:filter].delete(:in)

      cached_results = find_cached_results(args[1])
      return cached_results if cached_results || cached_results.nil?

      options[:in] = [options[:in].to_s, @@settings[:base]].delete_if(&:empty?).join(',')

      if options[:filter].is_a? Hash
        options[:filter] = make_filter_from_hash(options[:filter])
      end

      options[:filter] = options[:filter] & filter unless filter == NIL_FILTER

      if scope == :all
        find_all(options)
      elsif scope == :first
        find_first(options)
      else
        raise ArgumentError, 'Invalid scope (not :all or :first) passed to find'
      end
    end

    ##
    # Searches the cache and returns the result
    # Returns false on failure, nil on wrong object type
    #
    def self.find_cached_results(filters)
      return false unless cache?

      # Check to see if we're only looking for :distinguishedname
      return false unless filters.is_a?(Hash) && filters.keys == [:distinguishedname]

      # Find keys we're looking up
      dns = filters[:distinguishedname]

      if dns.is_a? Array
        result = []

        dns.each do |dn|
          entry = @@cache[dn]

          # If the object isn't in the cache just run the query
          return false if entry.nil?

          # Only permit objects of the type we're looking for
          result << entry if entry.is_a? self
        end

        return result
      else
        return false unless @@cache.key? dns
        return @@cache[dns] if @@cache[dns].is_a? self
      end
    end

    def self.find_all(options)
      results = []
      ldap_objs = @@ldap.search(filter: options[:filter], base: options[:in]) || []

      ldap_objs.each do |entry|
        ad_obj = new(entry)
        @@cache[entry.dn] = ad_obj unless ad_obj.instance_of? Base
        results << ad_obj
      end

      results
    end

    def self.find_first(options)
      ldap_result = @@ldap.search(filter: options[:filter], base: options[:in])
      return nil if ldap_result.empty?

      ad_obj = new(ldap_result[0])
      @@cache[ad_obj.dn] = ad_obj unless ad_obj.instance_of? Base
      ad_obj
    end

    def self.method_missing(name, *args) # :nodoc:
      name = name.to_s
      if name[0, 5] == 'find_'
        find_spec, attribute_spec = parse_finder_spec(name)
        raise ArgumentError, "find: Wrong number of arguments (#{args.size} for #{attribute_spec.size})" unless args.size == attribute_spec.size
        filters = {}
        [attribute_spec, args].transpose.each { |pr| filters[pr[0]] = pr[1] }
        find(find_spec, filter: filters)
      else
        super name.to_sym, args
      end
    end

    def self.parse_finder_spec(method_name) # :nodoc:
      # FIXME: This is a prime candidate for a
      # first-class object, FinderSpec

      method_name = method_name.gsub(/^find_/, '').gsub(/^by_/, 'first_by_')
      find_spec, attribute_spec = *method_name.split('_by_')
      find_spec = find_spec.to_sym
      attribute_spec = attribute_spec.split('_and_').collect(&:to_sym)

      [find_spec, attribute_spec]
    end

    def ==(other) # :nodoc:
      return false if other.nil?
      other[:objectguid] == get_attr(:objectguid)
    end

    #
    # Returns true if this entry does not yet exist in Active Directory.
    #
    def new_record?
      @entry.nil?
    end

    #
    # Refreshes the attributes for the entry with updated data from the
    # domain controller.
    #
    def reload
      return false if new_record?

      @entry = @@ldap.search(filter: Net::LDAP::Filter.eq('distinguishedName', distinguishedName))[0]
      !@entry.nil?
    end

    #
    # Updates a single attribute (name) with one or more values
    # (value), by immediately contacting the Active Directory
    # server and initiating the update remotely.
    #
    # Entries are always reloaded (via Base.reload) after calling
    # this method.
    #
    def update_attribute(name, value)
      update_attributes(name.to_s => value)
    end

    #
    # Updates multiple attributes, like ActiveRecord#update_attributes.
    # The updates are immediately sent to the server for processing,
    # and the entry is reloaded after the update (if all went well).
    #
    def update_attributes(attributes_to_update)
      return true if attributes_to_update.empty?
      rename = false

      operations = []
      attributes_to_update.each do |attribute, values|
        if attribute == :cn
          rename = true
        else
          if values.nil? || values.to_s.empty?
            operations << [:delete, attribute, nil]
          else
            values = [values] unless values.is_a? Array
            values = values.collect(&:to_s)

            current_value = begin
                              @entry[attribute]
                            rescue NoMethodError
                              nil
                            end

            operations << [(current_value.nil? ? :add : :replace), attribute, values]
          end
        end
      end

      unless operations.empty?
        @@ldap.modify(
          dn: distinguishedName,
          operations: operations
        )
      end
      if rename
        @@ldap.modify(
          dn: distinguishedName,
          operations: [[(name.nil? ? :add : :replace), 'samaccountname', attributes_to_update[:cn]]]
        )
        @@ldap.rename(olddn: distinguishedName, newrdn: 'cn=' + attributes_to_update[:cn], delete_attributes: true)
      end
      reload
    end

    #
    # Create a new entry in the Active Record store.
    #
    # dn is the Distinguished Name for the new entry.	This must be
    # a unique identifier, and can be passed as either a Container
    # or a plain string.
    #
    # attributes is a symbol-keyed hash of attribute_name => value
    # pairs.
    #
    def self.create(dn, attributes)
      return nil if dn.nil? || attributes.nil?
      begin
        attributes.merge!(required_attributes)
        if @@ldap.add(dn: dn.to_s, attributes: attributes)
          ldap_obj = @@ldap.search(base: dn.to_s)
          return new(ldap_obj[0])
        else
          return nil
        end
      rescue
        return nil
      end
    end

    #
    # Deletes the entry from the Active Record store and returns true
    # if the operation was successfully.
    #
    def destroy
      return false if new_record?

      if @@ldap.delete(dn: distinguishedName)
        @entry = nil
        @attributes = {}
        return true
      else
        return false
      end
    end

    #
    # Saves any pending changes to the entry by updating the remote
    # entry.
    #
    def save
      if update_attributes(@attributes)
        @attributes = {}
        true
      else
        false
      end
    end

    #
    # This method may one day provide the ability to move entries from
    # container to container. Currently, it does nothing, as we are
    # waiting on the Net::LDAP folks to either document the
    # Net::LDAP#modrdn method, or provide a similar method for
    # moving / renaming LDAP entries.
    #
    # FIXME Why are we creating a new LDAP connection here? This doesn't fit with
    # the 'pattern' used for this library (exposes a single LDAP connection, not
    # multiple LDAP connection instances.)
    def move(superior, new_rdn: nil)
      return false if new_record?
      new_rdn = new_rdn ? new_rdn : "CN=#{get_attr(:cn)}"
      puts 'hello from my fork - updated'
      puts "Moving #{get_attr(:dn)} to #{new_rdn},#{superior}"

      @@ldap.rename(
        olddn: get_attr(:dn),
        newrdn: new_rdn,
        delete_attributes: true,
        new_superior: superior
      )
    end

    # FIXME: Need to document the Base::new
    def initialize(attributes = {}) # :nodoc:
      if attributes.is_a? Net::LDAP::Entry
        @entry = attributes
        @attributes = {}
      else
        @entry = nil
        @attributes = attributes
      end
    end

    ##
    # Pull the class we're in
    # This isn't quite right, as extending the object does funny things to how we
    # lookup objects
    def self.class_name
      @klass ||= (name.include?('::') ? name[/.*::(.*)/, 1] : name)
    end

    ##
    # Grabs the field type depending on the class it is called from
    # Takes the field name as a parameter
    def self.get_field_type(name)
      # Extract class name
      throw 'Invalid field name' if name.nil?
      type = ::ActiveDirectory.special_fields[class_name.to_sym][name.to_s.downcase.to_sym]
      type.to_s unless type.nil?
    end

    @types = {}

    def self.decode_field(name, value) # :nodoc:
      type = get_field_type name
      if !type.nil? && ::ActiveDirectory::FieldType.const_defined?(type)
        return ::ActiveDirectory::FieldType.const_get(type).decode(value)
      end
      value
    end

    def self.encode_field(name, value) # :nodoc:
      type = get_field_type name
      if !type.nil? && ::ActiveDirectory::FieldType.const_defined?(type)
        return ::ActiveDirectory::FieldType.const_get(type).encode(value)
      end
      value
    end

    def valid_attribute?(name)
      @attributes.key?(name) || @entry.attribute_names.include?(name)
    end

    def get_attr(name)
      name = name.to_s.downcase

      return self.class.decode_field(name, @attributes[name.to_sym]) if @attributes.key?(name.to_sym)

      if @entry.attribute_names.include? name.to_sym
        value = @entry[name.to_sym]
        value = value.first if value.is_a?(Array) && value.size == 1
        value = value.to_s if value.nil? || value.size == 1
        value = nil.to_s if value.empty?
        return self.class.decode_field(name, value)
      end
    end

    def set_attr(name, value)
      @attributes[name.to_sym] = self.class.encode_field(name, value)
    end

    ##
    # Reads the array of values for the provided attribute. The attribute name
    # is canonicalized prior to reading. Returns an empty array if the
    # attribute does not exist.
    alias [] get_attr
    alias []= set_attr

    ##
    # Weird fluke with flattening, probably because of above attribute
    def to_ary; end

    def sid
      unless @sid
        raise 'Object has no sid' unless valid_attribute? :objectsid
        # SID is stored as a binary in the directory
        # however, Net::LDAP returns an hex string
        #
        # As per [1], there seems to be 2 ways to get back binary data.
        #
        # [str].pack("H*")
        # str.gsub(/../) { |b| b.hex.chr }
        #
        # [1] :
        # http://stackoverflow.com/questions/22957688/convert-string-with-hex-ascii-codes-to-characters
        #
        @sid = SID.read([get_attr(:objectsid)].pack('H*'))
      end
      @sid.to_s
    end

    def method_missing(name, args = []) # :nodoc:
      name_s = name.to_s.downcase

      return set_attr(name_s.chop, args) if name_s[-1] == '='

      if valid_attribute? name.to_sym
        get_attr(name.to_sym)
      else
        super
      end
    end
  end
end
