module FerretMixin
  module Acts #:nodoc:
    module ARFerret #:nodoc:

      module MoreLikeThis

        # returns other instances of this class, which have similar contents
        # like this one. Basically works like this: find out n most interesting
        # (i.e. characteristic) terms from this document, and then build a
        # query from those which is run against the whole index. Which terms
        # are interesting is decided on variour criteria which can be
        # influenced by the given options. 
        #
        # The algorithm used here is a quite straight port of the MoreLikeThis class
        # from Apache Lucene.
        #
        # options are:
        # :field_names : Array of field names to use for similarity search (mandatory)
        # :min_term_freq => 2,  # Ignore terms with less than this frequency in the source doc.
        # :min_doc_freq => 5,   # Ignore words which do not occur in at least this many docs
        # :min_word_length => nil, # Ignore words if less than this len (longer
        # words tend to be more characteristic for the document they occur in).
        # :max_word_length => nil, # Ignore words if greater than this len.
        # :max_query_terms => 25,  # maximum number of terms in the query built
        # :max_num_tokens => 5000, # maximum number of tokens to examine in a
        # single field
        # :boost => false,         # when true, a boost according to the
        # relative score of a term is applied to this Term's TermQuery.
        # :similarity => Ferret::Search::Similarity.default, # the similarity
        # implementation to use
        # :analyzer => Ferret::Analysis::StandardAnalyzer.new # the analyzer to
        # use
        # :append_to_query => nil # proc taking a query object as argument, which will be called after generating the query. can be used to further manipulate the query used to find related documents, i.e. to constrain the search to a given class in single table inheritance scenarios
        # find_options : options handed over to find_by_contents
        def more_like_this(options = {}, find_options = {})
          options = {
            :field_names => nil,  # Default field names
            :min_term_freq => 2,  # Ignore terms with less than this frequency in the source doc.
            :min_doc_freq => 5,   # Ignore words which do not occur in at least this many docs
            :min_word_length => 0, # Ignore words if less than this len. Default is not to ignore any words.
            :max_word_length => 0, # Ignore words if greater than this len. Default is not to ignore any words.
            :max_query_terms => 25,  # maximum number of terms in the query built
            :max_num_tokens => 5000, # maximum number of tokens to analyze when analyzing contents
            :boost => false,      
            :similarity => Ferret::Search::Similarity.default,
            :analyzer => Ferret::Analysis::StandardAnalyzer.new,
            :append_to_query => nil,
            :base_class => self.class # base class to use for querying, useful in STI scenarios where BaseClass.find_by_contents can be used to retrieve results from other classes, too
          }.update(options)
          index = self.class.ferret_index
          begin
            reader = index.send(:reader)
          rescue
            # ferret >=0.9, C-Version doesn't allow access to Index#reader
            reader = Ferret::Index::IndexReader.open(Ferret::Store::FSDirectory.new(self.class.class_index_dir, false))
          end
          doc_number = self.document_number
          term_freq_map = retrieve_terms(document_number, reader, options)
          priority_queue = create_queue(term_freq_map, reader, options)
          query = create_query(priority_queue, options)
          options[:append_to_query].call(query) if options[:append_to_query]
          options[:base_class].find_by_contents(query, find_options)
        end

        
        def create_query(priority_queue, options={})
          query = Ferret::Search::BooleanQuery.new
          qterms = 0
          best_score = nil
          while(cur = priority_queue.pop)
            term_query = Ferret::Search::TermQuery.new(cur.to_term)
            
            if options[:boost]
              # boost term according to relative score
              # TODO untested
              best_score ||= cur.score
              term_query.boost = cur.score / best_score
            end
            begin
              query.add_query(term_query, :should) 
            rescue Ferret::Search::BooleanQuery::TooManyClauses
              break
            end
            qterms += 1
            break if options[:max_query_terms] > 0 && qterms >= options[:max_query_terms]
          end
          # exclude ourselves
          t = Ferret::Index::Term.new('id', self.id.to_s)
          query.add_query(Ferret::Search::TermQuery.new(t), :must_not)
          return query
        end

        
        def document_number
          hits = self.class.ferret_index.search("id:#{self.id}")
          hits.each { |hit, score| return hit }
        end

        # creates a term/term_frequency map for terms from the fields
        # given in options[:field_names]
        def retrieve_terms(doc_number, reader, options)
          field_names = options[:field_names]
          max_num_tokens = options[:max_num_tokens]
          term_freq_map = Hash.new(0)
          doc = nil
          field_names.each do |field|
            term_freq_vector = reader.get_term_vector(document_number, field)
            if term_freq_vector
              # use stored term vector
              # TODO untested
              term_freq_vector.terms.each_with_index do |term, i|
                term_freq_map[term] += term_freq_vector.freqs[i] unless noise_word?(term, options)
              end
            else
              # no term vector stored, but we have stored the contents in the index
              # -> extract terms from there
              doc ||= reader.get_document(doc_number)
              content = doc[field]
              unless content
                # no term vector, no stored content, so try content from this instance
                content = content_for_field_name(field)
              end
              token_count = 0
              
              # C-Ferret >=0.9 again, no #each in tokenstream :-(
              ts = options[:analyzer].token_stream(field, content)
              while token = ts.next
              #options[:analyzer].token_stream(field, doc[field]).each do |token|
                break if (token_count+=1) > max_num_tokens
                next if noise_word?(token_text(token), options)
                term_freq_map[token_text(token)] += 1
              end
            end
          end
          term_freq_map
        end

        # extract textual value of a token
        def token_text(token)
          # token.term_text is for ferret 0.3.2
          token.respond_to?(:text) ? token.text : token.term_text
        end

        # create an ordered(by score) list of word,fieldname,score 
        # structures
        def create_queue(term_freq_map, reader, options)
          pq = Array.new(term_freq_map.size)
          
          similarity = options[:similarity]
          num_docs = reader.num_docs
          term_freq_map.each_pair do |word, tf|
            # filter out words that don't occur enough times in the source
            next if options[:min_term_freq] && tf < options[:min_term_freq]
            
            # go through all the fields and find the largest document frequency
            top_field = options[:field_names].first
            doc_freq = 0
            options[:field_names].each do |field_name| 
              freq = reader.doc_freq(Ferret::Index::Term.new(field_name, word))
              if freq > doc_freq 
                top_field = field_name
                doc_freq = freq
              end
            end
            # filter out words that don't occur in enough docs
            next if options[:min_doc_freq] && doc_freq < options[:min_doc_freq]
            next if doc_freq == 0 # index update problem ?
            
            idf = similarity.idf(doc_freq, num_docs)
            score = tf * idf
            pq << FrequencyQueueItem.new(word, top_field, score)
          end
          pq.compact!
          pq.sort! { |a,b| a.score<=>b.score }
          return pq
        end
        
        def noise_word?(text, options)
          len = text.length
          (
            (options[:min_word_length] > 0 && len < options[:min_word_length]) ||
            (options[:max_word_length] > 0 && len > options[:max_word_length]) ||
            (options[:stop_words] && options.include?(text))
          )
        end

        def content_for_field_name(field)
          self[field] || self.instance_variable_get("@#{field.to_s}".to_sym) || self.send(field.to_sym)
        end

      end

      class FrequencyQueueItem
        attr_reader :word, :field, :score
        def initialize(word, field, score)
          @word = word; @field = field; @score = score
        end
        def to_term
          Ferret::Index::Term.new(self.field, self.word)
        end
      end

    end
  end
end

