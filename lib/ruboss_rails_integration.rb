# Ruboss Patches

# Flex specific XML mime-type
Mime::Type.register_alias "application/xml", :fxml

# Flex friendly date, datetime formats
ActiveSupport::CoreExtensions::Date::Conversions::DATE_FORMATS.merge!(:flex => "%Y/%m/%d")
ActiveSupport::CoreExtensions::Time::Conversions::DATE_FORMATS.merge!(:flex => "%Y/%m/%d %H:%M:%S")

Hash::XML_FORMATTING['date'] = Proc.new { |date| date.to_s(:flex) }
Hash::XML_FORMATTING['datetime'] = Proc.new { |datetime| datetime.to_s(:flex) }

class String
  def capitalize_without_downcasing
    self[0,1].capitalize + self[1..-1]
  end
  def downcase_first_letter
    self[0,1].downcase + self[1..-1]
  end
end

module Ruboss
  def self.root
    defined?(RAILS_ROOT) ? RAILS_ROOT : Merb.root
  end
  
  module Configuration
    def extract_names
      project_name = Ruboss.root.split("/").last.capitalize
      project_name_downcase = project_name.downcase

      begin      
        config = YAML.load(File.open("#{RAILS_ROOT}/config/ruboss.yml"))
        base_package = config['base-package'] || project_name_downcase
        base_folder = base_package.gsub('.', '/')
        controller_name = config['controller-name'] || "#{project_name}Controller"
      rescue
        base_folder = base_package = project_name_downcase
        controller_name = "#{project_name}Controller"
      end
      [project_name, project_name_downcase, controller_name, base_package, base_folder]
    end

    def list_as_files(dir_name)
      Dir.entries(dir_name).grep(/\.as$/).map { |name| name.sub(/\.as$/, "") }.join(", ")
    end

    def list_mxml_files(dir_name)
      Dir.entries(dir_name).grep(/\.mxml$/).map { |name| name.sub(/\.mxml$/, "") }
    end
  end
end

class ArrayWithClassyToXml < Array
  def initialize(class_name)
    @class_name = class_name
  end
  def to_fxml(*args) # You need the *args so that it doesn't fail if there are :include or :methods params
    empty? ? "<#{@class_name} type=\"array\"/>" : to_xml
  end
end

module ActiveSupport
  module CoreExtensions
    module Hash
      module Conversions
        def to_fxml(options = {})
          options.merge!(:dasherize => false)
          to_xml(options)
        end
      end
    end
    module Array
      module Conversions
        def to_fxml(options = {})
          options.merge!(:dasherize => false)
          to_xml(options)
        end
      end
    end
  end
end

module ActionController
  class Base
    alias_method :old_render, :render unless method_defined?(:old_render)
   
    # so that we can have handling for :fxml option and write code like
    # format.fxml  { render :fxml => @projects }
    def render(options = nil, extra_options = {}, &block)
      if options && options[:fxml]
        xml = options[:fxml]
        response.content_type ||= Mime::XML
        render_for_text(xml.respond_to?(:to_fxml) ? xml.to_fxml : xml, options[:status])
      else
        old_render(options, extra_options, &block)
      end
    end
  end
end

module ActiveRecord
  # Flex friendly XML serialization patches
  class Base
    class << self
      alias_method :old_find, :find unless method_defined?(:old_find)

      def find(*args)
        result = old_find(*args)
        if result.class == Array and result.empty?
          result = ArrayWithClassyToXml.new(self.class_name.tableize)
        end
        result
      end
      
      def default_xml_methods(*args)
        methods = *args.dup
        module_eval <<-END 
            def self.default_xml_methods_array
              return [#{methods.inspect}].flatten
            end
          END
      end
      
      def default_xml_includes(*args)
        includes = *args.dup
        module_eval <<-END
          def self.default_xml_include_param
            return [#{includes.inspect}].flatten
          end
        END
      end
    end
  end
  
  module Serialization
    alias_method :old_to_xml, :to_xml unless method_defined?(:old_to_xml)
    
    def to_xml(options = {})
      options[:methods] = [options[:methods] || []].flatten + self.class.default_xml_methods_array if self.class.respond_to?(:default_xml_methods_array)      
      options[:include] = [options[:include] || []].flatten + self.class.default_xml_include_param if self.class.respond_to?(:default_xml_include_param)
      old_to_xml(options)
    end
    
    # Change this.  Don't open up to_xml.  Instead, generate the include hash by starting with the current includes and adding any 
    # default_fxml_includes found on the included models.
    def to_fxml(options = {})
      options.merge!(:dasherize => false)      
      default_except = [:crypted_password, :salt, :remember_token, :remember_token_expires_at]
      options[:except] = (options[:except] ? options[:except] + default_except : default_except)
      to_xml(options)
    end
  end
  
  # Change the xml serializer so that '?'s are stripped from attribute names.
  # This makes it possible to serialize methods that end in a question mark, like 'valid?' or 'is_true?'
  class XmlSerializer
    def add_tag(attribute)
      builder.tag!(
        dasherize? ? attribute.display_name.dasherize : attribute.display_name,
        attribute.value.to_s,
        attribute.decorations(!options[:skip_types])
      )
    end    
    class Attribute
      def display_name
        @name.gsub('?','')
      end
    end
  end
  
  # Add more extensive reporting on errors including field name along with a message
  # when errors are serialized to XML
  class Errors
    def to_fxml(options={})
      options[:root] ||= "errors"
      options[:indent] ||= 2
      options[:builder] ||= Builder::XmlMarkup.new(:indent => options[:indent])
      options[:builder].instruct! unless options.delete(:skip_instruct)
      options[:builder].errors do |e|
        # The @errors instance variable is a Hash inside the Errors class
        @errors.each_key do |attr|
          @errors[attr].each do |msg|
            next if msg.nil?
            if attr == "base"
              options[:builder].error("message" => msg)
            else
              fullmsg = @base.class.human_attribute_name(attr) + ' ' + msg
              options[:builder].error("field" => attr.camelcase(:lower), "message" => fullmsg)
            end
          end
        end
      end
    end  
  end
  
end