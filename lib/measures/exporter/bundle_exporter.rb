module Measures
  module Exporter
    class BundleExporter

      attr_accessor :measures
      attr_accessor :config
      attr_accessor :records
      
      DEFAULTS = {"library_path" => "library_functions",
                  "measures_path" => "measures",
                  "sources_path" => "sources",
                  "records_path" => "patients",
                  "results_path" => "results",
                  "valuesets_path" => "value_sets",
                  "base_dir" => "./bundle",
                  "enable_logging" => false,
                  "enable_rationale" =>false,
                  "effective_date" => Measure::DEFAULT_EFFECTIVE_DATE,
                  "name" =>"bundle-#{Time.now.to_i}",
                  "check_crosswalk" => false,
                  "export_filter" => ["measures", "sources","records", "valuesets", "results"]}
      
      DEFAULTS.keys.each do |k|
        attr_accessor k.to_sym
      end

      def initialize(measures=Measure.all, config={})
        @config = DEFAULTS.merge(config)
        @measures = measures
        @records =  Record.where(type: {"$in" => measures.pluck(:type).uniq})
        DEFAULTS.keys.each do |name|
          instance_variable_set("@#{name}", @config[name])
        end

      end



      def rebuild_measures
        HealthDataStandards::CQM::Bundle.where({}).destroy
        HealthDataStandards::CQM::QueryCache.where({}).destroy
        HealthDataStandards::CQM::PatientCache.where({}).destroy
        #clear bundles
        #clear results
        QME::QualityMeasure.where({}).destroy
        dummy_bundle = HealthDataStandards::CQM::Bundle.new(name: "dummy",version: "1", extensions: BundleExporter.refresh_js_libraries(check_crosswalk).keys)
        dummy_bundle.save!
        @measures.each do |mes|
            mes.populations.each_with_index do |population, index|
              measure_json = mes.measure_json(index, check_crosswalk)
              MONGO_DB["measures"].insert(measure_json)
            end
           # dummy_bundle.measure_ids << mes.hqmf_id
        end
        dummy_bundle.save!
        #insert all measures
      end

      def calculate     
         HealthDataStandards::CQM::Measure.where({:hqmf_id => {"$in" => measures.pluck(:hqmf_id).uniq}}).each do |measure|  
          draft_measure = Measure.where({:hqmf_id => measure.hqmf_id}).first
          oid_dictionary = HQMF2JS::Generator::CodesToJson.from_value_sets(draft_measure.value_sets)
          report = QME::QualityReport.find_or_create(measure.hqmf_id, measure.sub_id, {'effective_date' => effective_date, 'enable_logging' => enable_logging, "enable_rationale" =>enable_rationale})
          report.calculate({"oid_dictionary" =>oid_dictionary.to_json},false) unless report.calculated?
        end
      end

      def export
        clear_directories if @config["clear_directories"]

        export_measures if export_filter.index("measures")
        export_sources if export_filter.index("sources")
        export_patients if export_filter.index("records")
        export_results if export_filter.index("results")
        export_valuesets if export_filter.index("valuesets")
        
        if export_filter.index("measures")
          BundleExporter.library_functions.each_pair do |name,data|
            write_to_file File.join(library_path,name), data
          end
        end
        write_to_file "bundle.json", bundle_json
      end

      def export_patients
        exporter=HealthDataStandards::Export::HTML.new
        records.each do |patient|
          # puts "Exporting patient: #{patient.first}#{patient.last}"
          entries = Record::Sections.reduce([]) {|entries, section| entries.concat(patient[section.to_s] || []); entries }
          # puts "\tEntry Count != Source Data Criteria Count" if patient.source_data_criteria && entries.length != patient.source_data_criteria.length
          safe_first_name = patient.first.gsub("'", "")
          safe_last_name = patient.last.gsub("'", "")
          filename =  "#{safe_first_name}_#{safe_last_name}"
          
          patient_hash = patient.as_json(except: [ '_id', 'measure_id' ], methods: ['_type'])
          patient_hash['measure_ids'] = patient_hash['measure_ids'].uniq if patient_hash['measure_ids']
          json = JSON.pretty_generate(JSON.parse(patient_hash.remove_nils.to_json))
          html = exporter.export(patient)

          path = File.join(records_path, patient.type)
          write_to_file File.join(path, "json", "#{filename}.json"), json
          write_to_file File.join(path, "html", "#{filename}.html"), html

        end
      end

      def export_results
        results_by_patient = MONGO_DB['patient_cache'].find({}).to_a
        results_by_patient = JSON.pretty_generate(JSON.parse(results_by_patient.as_json(:except => [ '_id' ]).to_json))
        results_by_measure = MONGO_DB['query_cache'].find({}).to_a
        results_by_measure = JSON.pretty_generate(JSON.parse(results_by_measure.as_json(:except => [ '_id' ]).to_json))
        
        write_to_file File.join(results_path,"by_patient.json"), results_by_patient
        write_to_file File.join(results_path,"by_measure.json") ,results_by_measure
      end

      def export_valuesets

        value_sets = measures.map(&:value_set_oids).flatten.uniq
        value_sets.each do |oid|

          code_set_file = File.expand_path(File.join(config["valueset_sources"],"#{oid}.xml"))
          if File.exist? code_set_file
            write_to_file  File.join(valuesets_path, "xml", "#{oid}.xml"), File.read(code_set_file)
          else
            # puts("\tError generating code set for #{oid}")
          end
        end
        HealthDataStandards::SVS::ValueSet.where({oid: {'$in'=>value_sets}}).to_a.each do |vs|
           write_to_file File.join(valuesets_path,"json", "#{vs.oid}.json"), JSON.pretty_generate(vs.as_json(:except => [ '_id' ]), max_nesting: 250)
        end
      end

      def export_measures
        QME::QualityMeasure.where({:hqmf_id => {"$in" => measures.pluck(:hqmf_id).uniq}}).each do |measure|
          measure_json = JSON.pretty_generate(measure.as_json(:except => [ '_id' ]), max_nesting: 250)
          write_to_file File.join(measures_path, measure.type ,"#{measure['nqf_id']}#{measure['sub_id']}.json") ,measure_json
        end
      end

      def export_sources
        source_path = config["hqmf_path"]
        measures.each do |measure|
          if source_path
            html = File.read(File.expand_path(File.join(source_path, "html", "#{measure.hqmf_id}.html")))
            hqmf1 = File.read(File.expand_path(File.join(source_path, "hqmf", "#{measure.hqmf_id}.xml")))
            hqmf2 = HQMF2::Generator::ModelProcessor.to_hqmf(measure.as_hqmf_model) rescue puts("\tError generating HQMFv2 for #{measure.measure_id}")
            hqmf_model = JSON.pretty_generate(measure.as_hqmf_model.to_json, max_nesting: 250)

            sources = {}
            path = File.join(sources_path, measure.type,  measure.measure_id)
            write_to_file File.join(path, "#{measure.measure_id}.html"),html
            write_to_file File.join(path, "hqmf1.xml"), hqmf1
            write_to_file File.join(path, "hqmf2.xml"), hqmf2 if hqmf2
            write_to_file File.join(path, "hqmf_model.json"), hqmf_model
          end
        end
      end

      def self.library_functions(check_crosswalk=false)
        library_functions = {}
        library_functions['map_reduce_utils'] = HQMF2JS::Generator::JS.map_reduce_utils
        library_functions['hqmf_utils'] = HQMF2JS::Generator::JS.library_functions(check_crosswalk)
        library_functions
      end   
      
      def self.refresh_js_libraries(check_crosswalk=false)
        MONGO_DB['system.js'].find({}).remove_all
        libs = library_functions(check_crosswalk)
        libs.each do |name, contents|
          HealthDataStandards::Import::Bundle::Importer.save_system_js_fn(name, contents)
        end
        libs
      end

      def clear_directories
        FileUtils.rm_rf(ba)
      end

      def write_to_file(file_name, data)
        FileUtils.mkdir_p base_dir
        w_file_name = File.join(base_dir,file_name)
        FileUtils.mkdir_p File.dirname(w_file_name)
        FileUtils.remove_file(w_file_name,true)
        File.open(w_file_name,"w") do |f|
          f.puts data
        end

      end

      def compress_artifacts
        zipfile_name = config["name"] 
         Zip::ZipFile.open("#{zipfile_name}.zip",  Zip::ZipFile::CREATE) do |zipfile|
          Dir[File.join(base_dir, '**', '**')].each do |file|
             fname = file.sub(base_dir, '')
             if fname[0] == '/'
                fname = fname.slice(1,fname.length)
              end
             zipfile.add(fname, file)
           end
        end
        zipfile_name
      end


      def bundle_json
        json = {
          title: config['title'],
          measure_period_start: config['measure_period_start'],
          effective_date: config['effective_date'],
          active: true,
          bundle_format: '3.0.0',
          smoking_gun_capable: true,
          version: config['version'],
          license: config['license'],
          measures: measures.pluck(:hqmf_id).uniq,
          patients: records.pluck(:medical_record_number).uniq,
          exported: Time.now.strftime("%Y-%m-%d"),
          extensions: BundleExporter.refresh_js_libraries.keys
        }
      end
    end   
  end
end
