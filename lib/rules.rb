require 'ast'
require 'match_result'

module Grammy
	module Rules

		MAX_REPETITIONS = 10_000

		module Operators

			def self.included(target)
				cloned_mod = self.clone
				my_mod_name = name

				# store the module that is included
				target.class_eval {
					@@removable_modules ||= {}
					@@removable_modules[my_mod_name] = cloned_mod
				}

				# make backup of already defined methods
				cloned_mod.instance_methods.each {|imeth|
					if target.instance_methods.include? imeth
						target.send(:alias_method,"__#{imeth}_backup",imeth)
					end
				}

				cloned_mod.send(:append_features,target)
			end

			# removes the module from the target by
			# removing added methods and aliasing the backup
			# methods with their original name
			def self.exclude(target)
				# get the module
				mod = target.send(:class_eval){
					@@removable_modules
				}[name] || raise("module '#{name}' not found in internal hash, cant exclude it")

				# remove / restore the methods
				mod.instance_methods.each {|imeth|
					mod.send(:undef_method,imeth)

					if target.instance_methods.include? "__#{imeth}_backup"
						target.send(:alias_method,imeth,"__#{imeth}_backup")
						target.send(:undef_method,"__#{imeth}_backup")
					end
				}
			end

			def &(other)
				left = Rule.to_rule(self)
				left.backtracking = false
				Sequence.new(nil,[left,other], helper: true)
			end

			def >>(other)
				Sequence.new(nil,[self,other], helper: true)
			end

			def |(other)
				Alternatives.new(nil,[self,other], helper: true)
			end

			def *(times)
				times = times..times if times.is_a? Integer
				raise("times must be a range or int but was: '#{times}'") unless times.is_a? Range

				Repetition.new(nil,Rule.to_rule(self),times: times, helper: true)
			end

			def +@
				Repetition.new(nil,self,times: 1..MAX_REPETITIONS, helper: true)
			end
		end

		#
		# RULE
		#
		class Rule
			include Operators

			SourceTypes = [Rule,Array,Range,String,Integer,Symbol]

			attr_accessor :name, :options
			attr_reader :grammar

			def initialize(name,options={})
				@name = name
				@options = options
			end

			# For debugging purposes: returns the classname
			def rule_type
				self.class.name.split('::').last
			end

			def helper=(value)
				@options[:helper] = value
			end

			# true iff this rule is a helper rule. a rule is automatically a helper rule when it has no name.
			# a helper rule generates no AST::Node
			def helper?
				(@options[:helper] || !name)
			end
			
			def backtracking=(value)
				raise "invalid backtracking value: '#{value}'" unless [true,false].include? value
				@options[:backtracking] = value
			end

			def backtracking?
				@options[:backtracking]
			end

			def skipping=(value)
				raise "invalid skipping value: '#{value}'" unless [true,false].include? value
				@options[:skipping] = value
			end

			def skipping?
				grammar.skipper and @options[:skipping]
			end

			def ignored=value
				raise unless [true,false].member? value
				@options[:ignored] = value
			end

			# true when the matched string should not be part of the generated AST (like ',' or '(')
			def ignored?
				@options[:ignored]
			end

			def children
				raise "not implemented in #{self.class}"
			end

			def grammar=(gr)
				raise unless gr.is_a? Grammar
				@grammar = gr
				children.each{|rule|
					rule.grammar= gr if rule.kind_of? Rule
				}
			end

			def skip(stream,start)
				match = grammar.skipper.match(stream,start)
				
				if match.success?
					match.end_pos
				else
					match.start_pos
				end
			end

			def self.to_rule(input)
				case input
				when Range then RangeRule.new(:_range,input,helper: true)
				when Array then Alternatives.new(nil,input, helper: true)
				when Symbol then RuleWrapper.new(input,helper: true)
				when String then StringRule.new(input,helper: true)
				when Integer then StringRule.new(input.to_s,helper: true)
				when Rule then input
				else
					raise "invalid input '#{input}', cant convert to a rule"
				end
			end

			def to_s
				rule_type + '{' + children.join(',') + '}'
			end

			def debug_start(stream,start)
				str = case rule_type
					when "Sequence" then "Seq"
					when "Alternatives" then "Alt"
					when "RangeRule" then "Ran"
					when "RuleWrapper" then "Wrp"
					when "StringRule" then "Str"
					when "Repetition" then "Rep"
					else raise
				end

				Log4r::NDC.push(name || ':'+str)
				grammar.logger.debug("#{str}.match(#{stream[start..-1].inspect},#{start})")
			end

			def debug_end(match)
				data = match.ast_node.data if match.ast_node
				result = match.success? ? "SUCCESS" : "FAIL"
				grammar.logger.debug("--> #{result} => #{data.inspect},#{match.start_pos}..#{match.end_pos}")
				Log4r::NDC.pop
			end
		end

		#
		# RangeRule
		#
		class RangeRule < Rule
			attr_reader :range
			
			def initialize(name,range,options={})
				super(name,options)
				raise "range must be range but was: '#{range}'" unless range.is_a? Range
				@range = range
			end

			def children
				[]
			end

			def match(stream,start_pos)
				debug_start(stream,start_pos)
				success = false
				end_pos = start_pos
				
				matched_element = @range.find { |e|
					success = (e == stream[start_pos,e.length])
				}

				end_pos = start_pos + matched_element.length if success

				node = AST::Node.new(name, range: [start_pos,end_pos], merge: helper?, stream: stream) if success and not ignored?
				match = MatchResult.new(self,success,node,start_pos,end_pos)
				debug_end(match)
				match
			end
		end

		#
		# StringRule
		# 
		class StringRule < Rule
			def initialize(string,options={})
				super(nil,options)
				raise unless string.is_a? String
				@string = string
			end

			def string
				@string
			end

			def children
				[]
			end

			def match(stream,start_pos)
				debug_start(stream,start_pos)
				success = (@string == stream[start_pos,@string.length])

				end_pos = start_pos
				end_pos += @string.length if success

				node = AST::Node.new(name || :_str, range: [start_pos,end_pos], merge: helper?, stream: stream) if success and not ignored?
				match = MatchResult.new(self,success,node,start_pos,end_pos)

				debug_end(match)
				match
			end
		end

		#
		# RULE WRAPPER rule
		# Wraps a symbol which represents another rule which may be not defined yet.
		# When the symbol ends with '?', then the rule is optional
		class RuleWrapper < Rule
			def initialize(sym,options={})
				super(nil,options) # FIXME pass the name?
				raise("sym has to be a symbol but was: '#{sym}'") unless sym.is_a? Symbol
				@optional = false
				if sym[-1]=='?'
					@optional = true
					sym = sym[0..-2].to_sym
				end
				@symbol = sym
			end

			def name
				#rule.name
				@symbol
			end

			def optional?
				@optional
			end

			def grammar=(gr)
				# dont set grammar for children because the wrapped rule might not be defined yet
				# also the wrapped rule has a name (defined via rule-method), so it will get assigned a grammar anyway
				@grammar = gr
			end

			def children
				rule.children
			end

			def rule
				grammar.rules[@symbol] || raise("RuleWrapper: rule not found '#{@symbol}'")
			end

			def match(stream,start_pos)
				debug_start(stream,start_pos)
				
				match = rule.match(stream,start_pos)

				success = match.success? || optional?

				result = MatchResult.new(self, success, match.ast_node, match.start_pos, match.end_pos)
				
				debug_end(result)
				result
			end

		end

		#
		# SEQUENCE
		#
		class Sequence < Rule
			def initialize(name,seq,options={})
				#raise "seq.class must be in #{Rule::SourceTypes} but was #{seq.class}" unless Rule::SourceTypes.member? seq.class
				seq = seq.map{|elem| 
					if elem.is_a? Sequence and elem.helper?
						elem.children
					else
						elem
					end
				}.flatten
				
				seq = seq.map{|elem| Rule.to_rule(elem) }
				@sequence = seq
				super(name,options)
			end

			def children
				@sequence
			end

			def match(stream,start_pos)
				debug_start(stream,start_pos)
				
				results = [] # will store the MatchResult of each rule of the sequence
				cur_pos = start_pos

				# --find the first rule in the sequence that fails to match the input
				# - add the results of all succeeding rules to the match_results array
				failed = @sequence.find { |e|
					cur_pos = skip(stream,cur_pos) if skipping?
					match = e.match(stream,cur_pos)
					
					if match.success?
						results << match

						cur_pos = match.end_pos
					end

					:exit if match.failure? # end loop
				}

				end_pos = cur_pos

				unless ignored?
					node = AST::Node.new(name, merge: helper?, stream: stream, range: [start_pos,end_pos])
					results.each{|res| node.add_child(res.ast_node) if res.ast_node }
				end

				result = MatchResult.new(self,!failed,node,start_pos,end_pos)

				debug_end(result)
				result
			end

		end

		# ALTERNATIVE
		class Alternatives < Rule
			def initialize(name,alts,options={})
				@alternatives = alts.map{|r| Rule.to_rule(r) }
				super(name,options)
			end

			def children
				@alternatives
			end

			def match(stream,start_pos)
				debug_start(stream,start_pos)
				match = nil

				success = @alternatives.find { |e|
					start_pos = skip(stream,start_pos) if skipping?
					match = e.match(stream,start_pos)
					match.success?
				}

				unless ignored?
					node = AST::Node.new(name, merge: helper?, stream: stream)
					node.add_child(match.ast_node) if match.ast_node
					node.start_pos = start_pos
					node.end_pos = match.end_pos
				end

				result = MatchResult.new(self,!!success,node,start_pos,match.end_pos)
				debug_end(result)
				result
			end

		end

		# REPETITION
		class Repetition < Rule
			attr_accessor :repetitions

			def initialize(name,rule,options={})
				rule = Rule.to_rule(rule)
				@rule = rule
				@repetitions = options[:times] || raise("no repetition supplied")
				super(name,options)
			end

			def children
				[@rule]
			end

			def match(stream,start_pos)
				success = false # set to true when repetition in specified range
				failed = false # used for the loop
				cur_pos = start_pos
				
				results = []

				debug_start(stream,start_pos)

				while not failed and results.length < repetitions.max
					cur_pos = skip(stream,cur_pos) if skipping?
					match = @rule.match(stream,cur_pos)

					if match.success?
						results << match
						
						cur_pos = match.end_pos
					else
						failed = true
					end
				end

				success = repetitions.include? results.length
				end_pos = success ? cur_pos : start_pos
				
				unless ignored?
					node = AST::Node.new(name, merge: helper?, stream: stream)
					results.each{|res| node.add_child(res.ast_node) }
					node.start_pos = start_pos
					node.end_pos = end_pos
				end

				result = MatchResult.new(self, !!success, node, start_pos, end_pos)
				debug_end(result)
				result
			end

		end

	end # module Rules
end # module Grammy
