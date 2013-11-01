module ETL
  class InputError < StandardError; end


  class DatabaseLoader
    attr_accessor :source_file

    ## Constructor
    def initialize(source_info, object_map, column_map, source, documentation, subject=nil)
      generate_loader_map(object_map, column_map)
      generate_conditions(column_map)
      open_spreadsheet(source_info)
      
      @source = source
      @documentation = documentation
      @subject = subject      
    end

    def load_data
      unique_subjects = []
      #MY_LOG.info "In load_data"
      ActiveRecord::Base.transaction do
        #MY_LOG.info "In load_data transaction"
        # Process Existing Records that need to be destroyed
        destroy_existing_events?(@loader_map, @subject) if @subject.present?

        start_time = Time.zone.now()
        LOAD_LOG.info "########## Database Loader: Loading Data ##########"
        LOAD_LOG.info "##########  Starting at row #{@first_row}   ##########"

        (@first_row..@source_file.last_row).each do |i|

          #MY_LOG.info "##loader_map:\n#{@loader_map.to_yaml}"
          row = @source_file.row(i)
          next if skip_row?(row)
          row_subject = ensure_subject_available
          LOAD_LOG.info "###### LOADING ROW #{i}: #{(Time.zone.now() - start_time)/60} minutes elapsed" if i % 1000 == @first_row
          #MY_LOG.info "#{@loader_map}"
          @loader_map.each do |mapping|
            col_values = {}
            data_values = {}

            ## Destroy existing records if required, and only for single-row-per-subject files (aka subject cannot be supplied)
            destroy_existing_record?(mapping, row_subject) unless @subject.present?

            ## Map spreadsheet cell values to object fields
            mapping[:column_fields].each{|field, index| col_values[field] = cell_value(row, index)}
            mapping[:data_fields].each{|field,index| data_values[field.to_s] = cell_value(row, index)} if mapping[:data_fields]

            ## Determine number of objects to create
            attrs_list = determine_object_number(mapping, col_values, data_values)
            #MY_LOG.info "attrs_list: #{attrs_list}"

            ## Create all objects
            attrs_list.each do |attr_array|
              #MY_LOG.info "attr_array: #{attr_array}"

              col_attrs = attr_array[0]
              data_attrs = attr_array[1]

              # skip this object if all fields are nil
              next unless col_attrs.values.any? or data_attrs.values.any?

              ## Build Attributes
              obj_attrs = build_attributes(mapping, col_attrs, data_attrs, row_subject)

              # Clean Time Attributes if object is an event
              obj_attrs = clean_time_params(obj_attrs) if mapping[:class] == Event
              #MY_LOG.info "class: #{mapping[:class]} col: #{col_attrs} d: #{data_attrs} obj: #{obj_attrs} row_subject: #{row_subject}"

              ## Create Object

              # For existing records: update -
              obj = get_existing_object(mapping, obj_attrs) if mapping[:existing_records][:action] == :update or mapping[:existing_records][:action] == :ignore

              if obj

                ## Update - use logged update
                obj.logged_update(obj_attrs, @source.user, @source, @documentation) unless mapping[:existing_records][:action] == :ignore
              else
                ## Create
                if mapping[:class] == Event # Direct Create for Events to speed up load
                  #MY_LOG.info "\n#OBJ_ATTRS:\n#{obj_attrs}"
                  Event.direct_create(obj_attrs)
                else # Normal route for other classes
                  obj = mapping[:class].logged_new(obj_attrs, @source.user, @source, @documentation)
                  LOAD_LOG.error "##### WARNING!! Object failed to save: #{obj} | #{obj.errors.full_messages}" unless obj.save
                end
              end

              # Set Subject Association              
              set_subject_association(obj, mapping, row_subject)

              # Set loaded subject as row subject
              row_subject = obj if mapping[:class] == Subject
            end
            row_subject.touch
            unique_subjects << row_subject.subject_code unless unique_subjects.include? row_subject.subject_code
          end
        end # rows
        LOAD_LOG.info "TIME: #{(Time.zone.now() - start_time)/60} minutes"

      end # transaction
      LOAD_LOG.info "######################################################"
      LOAD_LOG.info "SUBJECTS LOADED IN TRANSACTION: #{unique_subjects}"
      LOAD_LOG.info "#{unique_subjects.length} IN TOTAL"
      LOAD_LOG.info "########## Database Loader: END TRANSACTION ##########\n\n"
      true
    end # method

    private

    def cell_value(row, index)
      # Allows for custom null markers
      if @empty_cell_markers.include?(row[index]) or row[index].blank?
        nil
      else
        row[index]
      end
    end

    def destroy_existing_record?(mapping, subject)
      if mapping[:existing_records][:action] == :destroy and mapping[:class] == Event and subject.present?
        LOAD_LOG.error "DESTROYING!!!!"
        Event.hard_delete(subject, mapping[:event_name])
      else
        false
      end
    end

    def destroy_existing_events?(map, subject)
    # Destroys all existing events if subject is already given. This needs to be done at the start of the transaction -
    # otherwise newly created events will be destroyed, since the same subject is present for each row.
      #MY_LOG.info "In destroy_existing_events?"

      map.each do |mapping|
        destroy_existing_record? mapping, subject
      end
    end


    def get_existing_object(mapping, obj_params)
      condition = Hash[mapping[:existing_records][:find_by].map{|x| [x, obj_params[x]]}]

      # fix for full_name
      if mapping[:class] == Researcher and condition.has_key?(:full_name)
        full_name = condition.delete(:full_name)
        split_name = Researcher.split_full_name(full_name)
        condition[:first_name] = split_name[:first_name]
        condition[:last_name] = split_name[:last_name]
      end

      #MY_LOG.info "m: #{mapping}\nc: #{condition}" if mapping[:class] == Researcher
      query_result = mapping[:class].where(condition)

      raise StandardError, "Object to update not unique" unless query_result.length < 2
      obj = (query_result ? query_result.first : nil)

      obj
    end

    def ensure_subject_available
      # either have subject mapping (use it), or have supplied object (mapping overrides it?)      
      if @subject.present?
        @subject
      else
        raise StandardError, "Subject not provided in row or initialization." if @loader_map.first[:class] != Subject
        nil
      end        
    end

    def build_attributes(mapping, col_attrs, data_attrs, row_subject)
      # Deal with missing hashes
      mapping[:static_fields] ||= {}

      # General

      obj_attrs = col_attrs.merge mapping[:static_fields] 

      # Event-specific
      if mapping[:class] == Event

        static_data_fields = {}
        mapping[:static_data_fields].each {|key, val| static_data_fields[key.to_s] = val} if mapping[:static_data_fields]
        obj_attrs[:event_dictionary] = mapping[:event_dictionary]
        obj_attrs[:name] = mapping[:event_name]

        obj_attrs[:source_id] = @source.id
        obj_attrs[:documentation_id] = @documentation.id
        obj_attrs[:data_list] = build_data_list data_attrs, static_data_fields
        obj_attrs[:subject_id] = row_subject.id

        #MY_LOG.info "Attributes: #{obj_attrs}\nMapping: #{mapping}"

        # Labtime and Realtime ==> a :labtime or :realtime key
        obj_attrs = set_event_time(obj_attrs, mapping)
      end
      obj_attrs
    end

    def set_event_time(obj_attrs, mapping)
      Time.zone = ActiveSupport::TimeZone.new("Eastern Time (US & Canada)")

      if obj_attrs[:labtime].present?
        fn_name = mapping[:labtime_fn].present? ? mapping[:labtime_fn] : "from_s"

        if fn_name == "from_s"
          obj_attrs[:labtime] = Labtime.send(fn_name, obj_attrs[:labtime], { year: obj_attrs[:labtime_year] })
        end
      elsif obj_attrs[:realtime].present? and mapping[:realtime_format].present?
        # if format not present, just use default loading of dates (excel-format cells seem to work)
        t = Time.strptime(mapping[:realtime], mapping[:realtime_format])
        obj_attrs[:realtime] = Time.zone.local(t.year, t.month, t.day, t.hour, t.min, t.sec)
      end

      obj_attrs
    end

    def build_data_list(data_attrs, static_data_fields)
      # Created to standardize data lists between direct create and normal create of events
      data_list = {clear_all: 0, list: []}
      (data_attrs.merge static_data_fields).each do |key, value|
        data_list[:list] << { title: key, value: value }
      end

      data_list
    end

    def determine_object_number(mapping, col_values, data_values)
      if mapping[:multiple]
        # Check if valid multiple value number across all fields
        #MY_LOG.info "col: #{col_values} dat: #{data_values}"
        split_vals = col_values.merge(data_values).values.map { |val| val ||= ""; val.split(';').map{|x| x.strip} }
        mult_count = split_vals.map{ |vals| vals.length }.uniq
        raise StandardError, "Numbers don't match up for multiple columns: #{mapping} \n#{col_values}" if mult_count.length != 1
        
        attrs_list = []
        
        # split column attributes for each instance of object that needs to be created
        mult_count.first.times do |n|
          # recreate hash
          attr_array = col_values.to_a.map{|key_val_pair| [key_val_pair[0], key_val_pair[1].split(';').map{|x| x.strip}[n]] }
          data_attr_array = data_values.to_a.map{|key_val_pair| [key_val_pair[0], key_val_pair[1].split(';').map{|x| x.strip}[n]] }

          attrs_list << [Hash[attr_array], Hash[data_attr_array]]          
        end
      else
        # If no multiple objects allowed, create an array of length 1
        attrs_list = [[col_values, data_values]]        
      end
      #MY_LOG.info "c: #{mapping[:class]} m?: #{mapping[:multiple]} \nc: #{col_values}\nattrs_list #{attrs_list}"

      attrs_list
    end

    def set_subject_association(obj, mapping, row_subject)

      if obj.class == Researcher
        obj.update_subject_association({type: mapping[:researcher_type], subject_id: row_subject.id, role: mapping[:role]})        
      elsif [Irb, Study, Publication].include?(obj.class)
        obj.subjects << row_subject unless obj.subjects.include?(row_subject)
      end
    end

    private 

    def open_spreadsheet(source_info)
      @source_file = case File.extname(source_info[:path]).downcase
        when '.csv' then Roo::CSV.new(source_info[:path], {file_warning: :ignore})
        when '.xls' then Roo::Excel.new(source_info[:path], {file_warning: :ignore})
        when '.xlsx' then Roo::Excelx.new(source_info[:path], {file_warning: :ignore})
        when '.dbf' then ETL::DbfReader.open(source_info[:path])
        else raise "Unknown file type: #{source_info[:path]}"
      end

      @source_file.default_sheet = source_info[:sheet].present? ? source_info[:sheet] : @source_file.sheets[0]

      @empty_cell_markers = source_info[:empty_cell_markers].present? ? source_info[:empty_cell_markers] : []
      @header = @source_file.row(1) if source_info[:header]
      @first_row = 1 + source_info[:skip_lines]
    end  

    def generate_conditions(column_map)
      @conditions = []
      column_map.each_with_index.map do |col, i|
        if col[:conditions].present?
          exec_string = col[:conditions].gsub("field", "cell_value(row, #{i})")
          @conditions << exec_string
        end
      end

      #MY_LOG.info "\n\nCONDITIONS: #####{@conditions}\n\n"

      @conditions
    end

    def skip_row?(row)
      if @conditions.present?
        skip = false
        @conditions.each do |c|
          skip = (skip or !eval(c))
        end
        #MY_LOG.info "skip row? #{skip}\n"
        skip
      else
        false
      end

    end

    def clean_time_params(event_params)
      # Input: ready-to-go params
      # Output: cleaned of all other time fields except :labtime xor :realtime
      raw_labtime_fields = [:labtime_year, :labtime_min, :labtime_sec, :labtime_hour]
      decimal_labtime_fields = [:labtime_year, :labtime_decimal]

      if (event_params.keys & raw_labtime_fields).sort == raw_labtime_fields.sort
        event_params[:labtime] = Labtime.new(event_params.delete(:labtime_year), event_params.delete(:labtime_hour), event_params.delete(:labtime_min), event_params.delete(:labtime_sec))
      elsif (event_params.keys & decimal_labtime_fields).sort == decimal_labtime_fields.sort
        event_params[:labtime] = Labtime.from_decimal(event_params.delete(:labtime_decimal).to_f, event_params.delete(:labtime_year))
      end

      raise StandardError, "Event params are missing a time field or have both realtime and labtime: #{event_params}" unless (event_params.keys.include?(:labtime) ^ event_params.keys.include?(:realtime))

      event_params
    end

    def generate_loader_map(object_map, column_map)
      @loader_map = object_map.map do |obj|
        class_sym = obj[:class].name.underscore.to_sym
        column_map = column_map.each_with_index.map {|col, i| col.merge({:col_index => i})}

        # Multiple entries!!!

        # column fields
        column_fields = column_map.select do |col| 
          col[:target] == class_sym and col[:researcher_type] == obj[:researcher_type] and col[:event_name] == obj[:event_name] and col[:role] == obj[:role]
        end

        # Get Labtime Function
        labtime_fn = column_fields.select{ |col| col[:labtime_fn].present? }
        labtime_fn = (labtime_fn.length == 1 ? labtime_fn.first[:labtime_fn] : nil)

        # Get Realtime format
        realtime_format = column_fields.select{ |col| col[:realtime_format].present? }
        realtime_format = (realtime_format.length == 1 ?  realtime_format.first[:realtime_format] : nil)


        multiple = column_fields.count{|x| x[:multiple].present? } > 0
        column_fields = Hash[column_fields.map{|col| [col[:field], col[:col_index]]}] # Convert to Hash

        # data fields
        if class_sym == :event
          data_fields = column_map.select do |col|
            col[:target] == :datum and col[:event_name] == obj[:event_name]
          end.map{|col| [col[:field], col[:col_index]]}
          data_fields = Hash[data_fields]
        end

        ## Build Loader Map Params
        # Required
        load_params = 
        {
          class: obj[:class],
          existing_records: obj[:existing_records],
          column_fields: column_fields,
        }
        # Static
        load_params[:static_fields] = obj[:static_fields] if obj[:static_fields].present?

        # Multiple
        load_params[:multiple] = true if multiple

        # Event-specific
        if class_sym == :event
          load_params[:event_name] = obj[:event_name]
          ed = EventDictionary.includes(:data_dictionary => :data_type).find_by_name(obj[:event_name])
          #MY_LOG.info "DOES THIS WORK: n: #{obj[:event_name]} ed: #{ed}"
          raise StandardError, "Can't find Event Dictionary Entry" unless ed
          load_params[:event_dictionary] = ed
          load_params[:data_fields] = data_fields if data_fields.present?
          load_params[:static_data_fields] = obj[:static_data_fields] if obj[:static_data_fields].present?
          load_params[:labtime_fn] = labtime_fn
          load_params[:realtime_format] = realtime_format
        end

        # Researcher-specific
        if class_sym == :researcher
          load_params[:researcher_type] = obj[:researcher_type]
          load_params[:role] = obj[:role].to_s
        end

        load_params
      end
    end
  end

end