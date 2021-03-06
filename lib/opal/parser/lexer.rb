require 'strscan'
require 'opal/parser/keywords'

module Opal
  class Lexer

    attr_reader :line, :scope_line, :scope

    attr_accessor :lex_state, :strterm

    def initialize(source, file)
      @lex_state  = :expr_beg
      @cond       = 0
      @cmdarg     = 0
      @line       = 1
      @file       = file

      @scanner = StringScanner.new(source)
      @scanner_stack = [@scanner]
    end

    def cond_push(n)
      @cond = (@cond << 1) | (n & 1)
    end

    def cond_pop
      @cond = @cond >> 1
    end

    def cond_lexpop
      @cond = (@cond >> 1) | (@cond & 1)
    end

    def cond?
      (@cond & 1) != 0
    end

    def cmdarg_push(n)
      @cmdarg = (@cmdarg << 1) | (n & 1)
    end

    def cmdarg_pop
      @cmdarg = @cmdarg >> 1
    end

    def cmdarg_lexpop
      @cmdarg = (@cmdarg >> 1) | (@cmdarg & 1)
    end

    def cmdarg?
      (@cmdarg & 1) != 0
    end

    def arg?
      [:expr_arg, :expr_cmdarg].include? @lex_state
    end

    def end?
      [:expr_end, :expr_endarg, :expr_endfn].include? @lex_state
    end

    def beg?
      [:expr_beg, :expr_value, :expr_mid, :expr_class].include? @lex_state
    end

    def after_operator?
      [:expr_fname, :expr_dot].include? @lex_state
    end

    def spcarg?
      arg? and @space_seen and !space?
    end

    def space?
      @scanner.check(/\s/)
    end

    def next_token
      self.yylex
    end

    def strterm_expand?(strterm)
      type = strterm[:type]

      [:dquote, :dsym, :dword, :heredoc, :xquote, :regexp].include? type
    end

    def next_string_token
      str_parse = self.strterm
      scanner = @scanner
      space = false

      expand = strterm_expand?(str_parse)

      words = ['w', 'W'].include? str_parse[:beg]

      space = true if ['w', 'W'].include?(str_parse[:beg]) and scanner.scan(/\s+/)

      # if not end of string, so we must be parsing contents
      str_buffer = []

      if str_parse[:type] == :heredoc
        eos_regx = /[ \t]*#{Regexp.escape(str_parse[:end])}(\r*\n|$)/

        if scanner.check(eos_regx)
          scanner.scan(/[ \t]*#{Regexp.escape(str_parse[:end])}/)
          self.strterm = nil

          if str_parse[:scanner]
            @scanner_stack << str_parse[:scanner]
            @scanner = str_parse[:scanner]
          end

          @lex_state = :expr_end
          return :tSTRING_END, scanner.matched
        end
      end

      # see if we can read end of string/xstring/regecp markers
      # if scanner.scan /#{str_parse[:end]}/
      if scanner.scan Regexp.new(Regexp.escape(str_parse[:end]))
        if words && !str_parse[:done_last_space]#&& space
          str_parse[:done_last_space] = true
          scanner.pos -= 1
          return :tSPACE, ' '
        end
        self.strterm = nil

        if str_parse[:balance]
          if str_parse[:nesting] == 0
            @lex_state = :expr_end

            if str_parse[:regexp]
              result = scanner.scan(/\w+/)
              return :tREGEXP_END, result
            end
            return :tSTRING_END, scanner.matched
          else
            str_buffer << scanner.matched
            str_parse[:nesting] -= 1
            self.strterm = str_parse
          end

        elsif ['"', "'"].include? str_parse[:beg]
          @lex_state = :expr_end
          return :tSTRING_END, scanner.matched

        elsif str_parse[:beg] == '`'
          @lex_state = :expr_end
          return :tSTRING_END, scanner.matched

        elsif str_parse[:beg] == '/' || str_parse[:regexp]
          result = scanner.scan(/\w+/)
          @lex_state = :expr_end
          return :tREGEXP_END, result

        else
          if str_parse[:scanner]
            @scanner_stack << str_parse[:scanner]
            @scanner = str_parse[:scanner]
          end

          @lex_state = :expr_end
          return :tSTRING_END, scanner.matched
        end
      end

      return :tSPACE, ' ' if space

      if str_parse[:balance] and scanner.scan Regexp.new(Regexp.escape(str_parse[:beg]))
        str_buffer << scanner.matched
        str_parse[:nesting] += 1
      elsif scanner.check(/#[@$]/)
        scanner.scan(/#/)
        if expand
          return :tSTRING_DVAR, scanner.matched
        else
          str_buffer << scanner.matched
        end

      elsif scanner.scan(/#\{/)
        if expand
          # we are into ruby code, so stop parsing content (for now)
          return :tSTRING_DBEG, scanner.matched
        else
          str_buffer << scanner.matched
        end

      # causes error, so we will just collect it later on with other text
      elsif scanner.scan(/\#/)
        str_buffer << '#'
      end

      if str_parse[:type] == :heredoc
        add_heredoc_content str_buffer, str_parse
      else
        add_string_content str_buffer, str_parse
      end

      complete_str = str_buffer.join ''
      @line += complete_str.count("\n")
      return :tSTRING_CONTENT, complete_str
    end

    def add_heredoc_content(str_buffer, str_parse)
      scanner = @scanner

      eos_regx = /[ \t]*#{Regexp.escape(str_parse[:end])}(\r*\n|$)/
      expand = true

      until scanner.eos?
        c = nil
        handled = true

        if scanner.scan(/\n/)
          c = scanner.matched
        elsif scanner.check(eos_regx) && scanner.bol?
          break # eos!
        elsif expand && scanner.check(/#(?=[\$\@\{])/)
          break
        elsif scanner.scan(/\\/)
          if str_parse[:regexp]
            if scanner.scan(/(.)/)
              c = "\\" + scanner.matched
            end
          else
            c = if scanner.scan(/n/)
              "\n"
            elsif scanner.scan(/r/)
              "\r"
            elsif scanner.scan(/\n/)
              "\n"
            elsif scanner.scan(/t/)
              "\t"
            else
              # escaped char doesnt need escaping, so just return it
              scanner.scan(/./)
              scanner.matched
            end
          end
        else
          handled = false
        end

        unless handled
          reg = Regexp.new("[^#{Regexp.escape str_parse[:end]}\#\0\\\\\n]+|.")

          scanner.scan reg
          c = scanner.matched
        end

        c ||= scanner.matched
        str_buffer << c
      end

      raise "reached EOF while in string" if scanner.eos?
    end

    def add_string_content(str_buffer, str_parse)
      scanner = @scanner
      # regexp for end of string/regexp
      # end_str_re = /#{str_parse[:end]}/
      end_str_re = Regexp.new(Regexp.escape(str_parse[:end]))

      expand = strterm_expand?(str_parse)

      words = ['W', 'w'].include? str_parse[:beg]

      until scanner.eos?
        c = nil
        handled = true

        if scanner.check end_str_re
          # eos
          # if its just balancing, add it ass normal content..
          if str_parse[:balance] && (str_parse[:nesting] != 0)
            # we only checked above, so actually scan it
            scanner.scan end_str_re
            c = scanner.matched
            str_parse[:nesting] -= 1
          else
            # not balancing, so break (eos!)
            break
          end

        elsif str_parse[:balance] and scanner.scan Regexp.new(Regexp.escape(str_parse[:beg]))
          str_parse[:nesting] += 1
          c = scanner.matched

        elsif words && scanner.scan(/\s/)
          scanner.pos -= 1
          break

        elsif expand && scanner.check(/#(?=[\$\@\{])/)
          break

        #elsif scanner.scan(/\\\\/)
          #c = scanner.matched

        elsif scanner.scan(/\\/)
          if str_parse[:regexp]
            if scanner.scan(/(.)/)
              c = "\\" + scanner.matched
            end
          else
            c = if scanner.scan(/n/)
              "\n"
            elsif scanner.scan(/r/)
              "\r"
            elsif scanner.scan(/\n/)
              "\n"
            elsif scanner.scan(/t/)
              "\t"
            else
              # escaped char doesnt need escaping, so just return it
              scanner.scan(/./)
              scanner.matched
            end 
          end
        else
          handled = false
        end

        unless handled
          reg = if words
                  Regexp.new("[^#{Regexp.escape str_parse[:end]}\#\0\n\ \\\\]+|.")
                elsif str_parse[:balance]
                  Regexp.new("[^#{Regexp.escape str_parse[:end]}#{Regexp.escape str_parse[:beg]}\#\0\\\\]+|.")
                else
                  Regexp.new("[^#{Regexp.escape str_parse[:end]}\#\0\\\\]+|.")
                end

          scanner.scan reg
          c = scanner.matched
        end

        c ||= scanner.matched
        str_buffer << c
      end

      raise "reached EOF while in string" if scanner.eos?
    end

    def heredoc_identifier
      if @scanner.scan(/(-?)['"]?(\w+)['"]?/)
        heredoc = @scanner[2]
        self.strterm = { :type => :heredoc, :beg => heredoc, :end => heredoc }

        # if ruby code at end of line after heredoc, we have to store it to
        # parse after heredoc is finished parsing
        end_of_line = @scanner.scan(/.*\n/)
        self.strterm[:scanner] = StringScanner.new(end_of_line) if end_of_line != "\n"

        return :tSTRING_BEG, heredoc
      end
    end

    def process_identifier(matched, cmd_start)
      scanner = @scanner
      matched = scanner.matched

      if scanner.peek(2) != '::' && scanner.scan(/:/)
        @lex_state = :expr_beg
        return :tLABEL, "#{matched}"
      end

      if matched == 'defined?'
        if after_operator?
          @lex_state = :expr_end
          return :tIDENTIFIER, matched
        end

        @lex_state = :expr_arg
        return :kDEFINED, 'defined?'
      end

      if matched.end_with? '?', '!'
        result = :tIDENTIFIER
      else
        if @lex_state == :expr_fname
          if scanner.scan(/\=/)
            result = :tIDENTIFIER
            matched += scanner.matched
          end

        elsif matched =~ /^[A-Z]/
          result = :tCONSTANT
        else
          result = :tIDENTIFIER
        end
      end

      if @lex_state != :expr_dot and kw = Keywords.keyword(matched)
        old_state = @lex_state
        @lex_state = kw.state

        if old_state == :expr_fname
          return [kw.id[0], kw.name]
        end

        if @lex_state == :expr_beg
          cmd_start = true
        end

        if matched == "do"
          if after_operator?
            @lex_state = :expr_end
            return :tIDENTIFIER, matched
          end

          if @start_of_lambda
            @start_of_lambda = false
            @lex_state = :expr_beg
            return [:kDO_LAMBDA, scanner.matched]
          elsif cond?
            @lex_state = :expr_beg
            return :kDO_COND, matched
          elsif cmdarg? && @lex_state != :expr_cmdarg
            @lex_state = :expr_beg
            return :kDO_BLOCK, matched
          elsif @lex_state == :expr_endarg
            return :kDO_BLOCK, matched
          else
            @lex_state = :expr_beg
            return :kDO, matched
          end
        else
          if old_state == :expr_beg or old_state == :expr_value
            return [kw.id[0], matched]
          else
            if kw.id[0] != kw.id[1]
              @lex_state = :expr_beg
            end

            return [kw.id[1], matched]
          end
        end
      end

      if [:expr_beg, :expr_dot, :expr_mid, :expr_arg, :expr_cmdarg].include? @lex_state
        @lex_state = cmd_start ? :expr_cmdarg : :expr_arg
      else
        @lex_state = :expr_end
      end

      return [matched =~ /^[A-Z]/ ? :tCONSTANT : :tIDENTIFIER, matched]
    end

    def yylex
      scanner = @scanner
      @space_seen = false
      cmd_start = false
      c = ''

      if self.strterm
        return next_string_token
      end

      while true
        if scanner.scan(/\ |\t|\r/)
          @space_seen = true
          next

        elsif scanner.scan(/(\n|#)/)
          c = scanner.matched
          if c == '#' then scanner.scan(/(.*)/) else @line += 1; end

          scanner.scan(/(\n+)/)
          @line += scanner.matched.length if scanner.matched

          next if [:expr_beg, :expr_dot].include? @lex_state

          if scanner.scan(/([\ \t\r\f\v]*)\./)
            @space_seen = true unless scanner[1].empty?
            scanner.pos = scanner.pos - 1

            next unless scanner.check(/\.\./)
          end

          cmd_start = true
          @lex_state = :expr_beg
          return '\\n', '\\n'

        elsif scanner.scan(/\;/)
          @lex_state = :expr_beg
          return ';', ';'

        elsif scanner.scan(/\*/)
          if scanner.scan(/\*/)
            if scanner.scan(/\=/)
              @lex_state = :expr_beg
              return :tOP_ASGN, '**'
            end

            if @lex_state == :expr_fname or @lex_state == :expr_dot
              @lex_state = :expr_arg
            else
              @lex_state = :expr_beg
            end

            return :tPOW, '**'

          else
            if scanner.scan(/\=/)
              @lex_state = :expr_beg
              return :tOP_ASGN, '*'
            end
          end

          if scanner.scan(/\*\=/)
            @lex_state = :expr_beg
            return :tOP_ASGN, '**'
          end

          if scanner.scan(/\*/)
            if after_operator?
              @lex_state = :expr_arg
            else
              @lex_state = :expr_beg
            end

            return :tPOW, '**'
          end

          if scanner.scan(/\=/)
            @lex_state = :expr_beg
            return :tOP_ASGN, '*'
          else
            result = '*'
            if @lex_state == :expr_fname or @lex_state == :expr_dot
              @lex_state = :expr_arg
              return :tSTAR2, result
            elsif @space_seen && scanner.check(/\S/)
              @lex_state = :expr_beg
              return :tSTAR, result
            elsif [:expr_beg, :expr_mid].include? @lex_state
              @lex_state = :expr_beg
              return :tSTAR, result
            else
              @lex_state = :expr_beg
              return :tSTAR2, result
            end
          end

        elsif scanner.scan(/\!/)
          c = scanner.scan(/./)
          if after_operator?
            @lex_state = :expr_arg
            if c == "@"
              return :tBANG, '!'
            end
          else
            @lex_state = :expr_beg
          end

          if c == '='
            return :tNEQ, '!='
          elsif c == '~'
            return :tNMATCH, '!~'
          end

          scanner.pos = scanner.pos - 1
          return :tBANG, '!'

        elsif scanner.scan(/\=/)
          if @lex_state == :expr_beg and !@space_seen
            if scanner.scan(/begin/) and space?
              scanner.scan(/(.*)/) # end of line
              line_count = 0

              while true
                if scanner.eos?
                  raise "embedded document meets end of file"
                end

                if scanner.scan(/\=end/) and space?
                  @line += line_count
                  return next_token
                end

                if scanner.scan(/\n/)
                  line_count += 1
                  next
                end

                scanner.scan(/(.*)/)
              end
            end
          end

          @lex_state = if after_operator?
                         :expr_arg
                       else
                         :expr_beg
                       end

          if scanner.scan(/\=/)
            if scanner.scan(/\=/)
              return :tEQQ, '==='
            end

            return :tEQ, '=='
          end

          if scanner.scan(/\~/)
            return :tMATCH, '=~'
          elsif scanner.scan(/\>/)
            return :tASSOC, '=>'
          end

          return :tEQL, '='

        elsif scanner.scan(/\"/)
          self.strterm = { :type => :dquote, :beg => '"', :end => '"' }
          return :tSTRING_BEG, scanner.matched

        elsif scanner.scan(/\'/)
          self.strterm = { :type => :squote, :beg => "'", :end => "'" }
          return :tSTRING_BEG, scanner.matched

        elsif scanner.scan(/\`/)
          self.strterm = { :type => :xquote, :beg => "`", :end => "`" }
          return :tXSTRING_BEG, scanner.matched

        elsif scanner.scan(/\&/)
          if scanner.scan(/\&/)
            @lex_state = :expr_beg

            if scanner.scan(/\=/)
              return :tOP_ASGN, '&&'
            end

            return :tANDOP, '&&'

          elsif scanner.scan(/\=/)
            @lex_state = :expr_beg
            return :tOP_ASGN, '&'
          end

          if spcarg?
            #puts "warning: `&' interpreted as argument prefix"
            result = '&@'
          elsif beg?
            result = '&@'
          else
            #puts "warn_balanced: & argument prefix"
            result = :tAMPER2
          end

          @lex_state = after_operator? ? :expr_arg : :expr_beg
          return result, '&'

        elsif scanner.scan(/\|/)
          if scanner.scan(/\|/)
            @lex_state = :expr_beg
            if scanner.scan(/\=/)
              return :tOP_ASGN, '||'
            end

            return :tOROP, '||'

          elsif scanner.scan(/\=/)
            return :tOP_ASGN, '|'
          end

          @lex_state = after_operator?() ? :expr_arg : :expr_beg
          return :tPIPE, '|'

        elsif scanner.scan(/\%W/)
          start_word  = scanner.scan(/./)
          end_word    = { '(' => ')', '[' => ']', '{' => '}' }[start_word] || start_word
          self.strterm = { :type => :dword, :beg => 'W', :end => end_word  }
          scanner.scan(/\s*/)
          return :tWORDS_BEG, scanner.matched

        elsif scanner.scan(/\%w/) or scanner.scan(/\%i/)
          start_word  = scanner.scan(/./)
          end_word    = { '(' => ')', '[' => ']', '{' => '}' }[start_word] || start_word
          self.strterm = { :type => :sword, :beg => 'w', :end => end_word }
          scanner.scan(/\s*/)
          return :tAWORDS_BEG, scanner.matched

        elsif scanner.scan(/\%[Qq]/)
          type = scanner.matched.end_with?('Q') ? :dquote : :squote
          start_word  = scanner.scan(/./)
          end_word    = { '(' => ')', '[' => ']', '{' => '}' }[start_word] || start_word
          self.strterm = { :type => type, :beg => start_word, :end => end_word, :balance => true, :nesting => 0 }
          return :tSTRING_BEG, scanner.matched

        elsif scanner.scan(/\%x/)
          start_word = scanner.scan(/./)
          end_word   = { '(' => ')', '[' => ']', '{' => '}' }[start_word] || start_word
          self.strterm = { :type => :xquote, :beg => start_word, :end => end_word, :balance => true, :nesting => 0 }
          return :tXSTRING_BEG, scanner.matched

        elsif scanner.scan(/\%r/)
          start_word = scanner.scan(/./)
          end_word   = { '(' => ')', '[' => ']', '{' => '}' }[start_word] || start_word
          self.strterm = { :type => :regexp, :beg => start_word, :end => end_word, :regexp => true, :balance => true, :nesting => 0 }
          return :tREGEXP_BEG, scanner.matched

        elsif scanner.scan(/\//)
          if [:expr_beg, :expr_mid].include? @lex_state
            self.strterm = { :type => :regexp, :beg => '/', :end => '/', :regexp => true }
            return :tREGEXP_BEG, scanner.matched
          elsif scanner.scan(/\=/)
            @lex_state = :expr_beg
            return :tOP_ASGN, '/'
          elsif @lex_state == :expr_fname or @lex_state == :expr_dot
            @lex_state = :expr_arg
          elsif @lex_state == :expr_cmdarg || @lex_state == :expr_arg
            if !scanner.check(/\s/) && @space_seen
              self.strterm = { :type => :regexp, :beg => '/', :end => '/', :regexp => true }
              return :tREGEXP_BEG, scanner.matched
            end
          else
            @lex_state = :expr_beg
          end

          return :tDIVIDE, '/'

        elsif scanner.scan(/\%/)
          if scanner.scan(/\=/)
            @lex_state = :expr_beg
            return :tOP_ASGN, '%'
          elsif scanner.check(/[^\s]/)
            if @lex_state == :expr_beg or (@lex_state == :expr_arg && @space_seen)
              start_word  = scanner.scan(/./)
              end_word    = { '(' => ')', '[' => ']', '{' => '}' }[start_word] || start_word
              self.strterm = { :type => :dquote, :beg => start_word, :end => end_word, :balance => true, :nesting => 0 }
              return :tSTRING_BEG, scanner.matched
            end
          end

          @lex_state = after_operator? ? :expr_arg : :expr_beg

          return :tPERCENT, '%'

        elsif scanner.scan(/\\/)
          if scanner.scan(/\r?\n/)
            @space_seen = true
            next
          end

          raise SyntaxError, "backslash must appear before newline :#{@file}:#{@line}"

        elsif scanner.scan(/\(/)
          result = scanner.matched
          if [:expr_beg, :expr_mid].include? @lex_state
            result = :tLPAREN
          elsif @space_seen && [:expr_arg, :expr_cmdarg].include?(@lex_state)
            result = :tLPAREN_ARG
          else
            result = '('
          end

          @lex_state = :expr_beg
          cond_push 0
          cmdarg_push 0

          return result, scanner.matched

        elsif scanner.scan(/\)/)
          cond_lexpop
          cmdarg_lexpop
          @lex_state = :expr_end
          return ')', scanner.matched

        elsif scanner.scan(/\[/)
          result = scanner.matched

          if [:expr_fname, :expr_dot].include? @lex_state
            @lex_state = :expr_arg
            if scanner.scan(/\]=/)
              return '[]=', '[]='
            elsif scanner.scan(/\]/)
              return '[]', '[]'
            else
              raise "Unexpected '[' token"
            end
          elsif [:expr_beg, :expr_mid].include?(@lex_state) || @space_seen
            @lex_state = :expr_beg
            cond_push 0
            cmdarg_push 0
            return '[', scanner.matched
          else
            @lex_state = :expr_beg
            cond_push 0
            cmdarg_push 0
            return '[@', scanner.matched
          end

        elsif scanner.scan(/\]/)
          cond_lexpop
          cmdarg_lexpop
          @lex_state = :expr_end
          return ']', scanner.matched

        elsif scanner.scan(/\}/)
          cond_lexpop
          cmdarg_lexpop
          @lex_state = :expr_end

          return '}', scanner.matched

        elsif scanner.scan(/\.\.\./)
          @lex_state = :expr_beg
          return :tDOT3, scanner.matched

        elsif scanner.scan(/\.\./)
          @lex_state = :expr_beg
          return :tDOT2, scanner.matched

        elsif scanner.scan(/\./)
          @lex_state = :expr_dot unless @lex_state == :expr_fname
          return '.', scanner.matched

        elsif scanner.scan(/\:\:/)
          if [:expr_beg, :expr_mid, :expr_class].include? @lex_state
            @lex_state = :expr_beg
            return '::@', scanner.matched
          elsif @space_seen && @lex_state == :expr_arg
            @lex_state = :expr_beg
            return '::@', scanner.matched
          end

          @lex_state = :expr_dot
          return '::', scanner.matched

        elsif scanner.scan(/\:/)
          if end? || scanner.check(/\s/)
            unless scanner.check(/\w/)
              @lex_state = :expr_beg
              return :tCOLON, ':'
            end

            @lex_state = :expr_fname
            return :tSYMBEG, ':'
          end

          if scanner.scan(/\'/)
            self.strterm = { :type => :ssym, :beg => "'", :end => "'" }
          elsif scanner.scan(/\"/)
            self.strterm = { :type => :dsym, :beg => '"', :end => '"' }
          end

          @lex_state = :expr_fname
          return :tSYMBEG, ':'

        elsif scanner.scan(/\^\=/)
          @lex_state = :expr_beg
          return :tOP_ASGN, '^'
        elsif scanner.scan(/\^/)
          if @lex_state == :expr_fname or @lex_state == :expr_dot
            @lex_state = :expr_arg
            return :tCARET, scanner.matched
          end

          @lex_state = :expr_beg
          return :tCARET, scanner.matched

        elsif scanner.check(/\</)
          if scanner.scan(/\<\<\=/)
            @lex_state = :expr_beg
            return :tOP_ASGN, '<<'
          elsif scanner.scan(/\<\</)
            if @lex_state == :expr_fname or @lex_state == :expr_dot
              @lex_state = :expr_arg
              return :tLSHFT, '<<'
            elsif ![:expr_dot, :expr_class].include?(@lex_state) && !end? && (!arg? || @space_seen)
              if token = heredoc_identifier
                return token
              end

              @lex_state = :expr_beg
              return :tLSHFT, '<<'
            end
            @lex_state = :expr_beg
            return :tLSHFT, '<<'
          elsif scanner.scan(/\<\=\>/)
            if after_operator?
              @lex_state = :expr_arg
            else
              if @lex_state == :expr_class
                cmd_start = true
              end

              @lex_state = :expr_beg
            end

            return :tCMP, '<=>'
          elsif scanner.scan(/\<\=/)
            if @lex_state == :expr_fname or @lex_state == :expr_dot
              @lex_state = :expr_arg
            else
              @lex_state = :expr_beg
            end
            return :tLEQ, '<='
          elsif scanner.scan(/\</)
            if @lex_state == :expr_fname or @lex_state == :expr_dot
              @lex_state = :expr_arg
            else
              @lex_state = :expr_beg
            end
            return :tLT, '<'
          end

        elsif scanner.check(/\>/)
          if scanner.scan(/\>\>\=/)
            return :tOP_ASGN, '>>'
          elsif scanner.scan(/\>\>/)
            if @lex_state == :expr_fname or @lex_state == :expr_dot
              @lex_state = :expr_arg
            else
              @lex_state = :expr_beg
            end
            return :tRSHFT, '>>'
          elsif scanner.scan(/\>\=/)
            if @lex_state == :expr_fname or @lex_state == :expr_dot
              @lex_state = :expr_end
            else
              @lex_state = :expr_beg
            end
            return :tGEQ, scanner.matched
          elsif scanner.scan(/\>/)
            if @lex_state == :expr_fname or @lex_state == :expr_dot
              @lex_state = :expr_arg
            else
              @lex_state = :expr_beg
            end
            return :tGT, '>'
          end

        elsif scanner.scan(/->/)
          # FIXME: # should be :expr_arg, but '(' breaks it...
          @lex_state = :expr_end
          @start_of_lambda = true
          return [:tLAMBDA, scanner.matched]

        elsif scanner.scan(/[+-]/)
          result  = scanner.matched
          sign    = result + '@'

          if @lex_state == :expr_beg || @lex_state == :expr_mid
            @lex_state = :expr_mid
            return [sign, sign]
          elsif @lex_state == :expr_fname or @lex_state == :expr_dot
            @lex_state = :expr_arg
            return [:tIDENTIFIER, result + scanner.matched] if scanner.scan(/@/)
            return [result, result]
          end

          if scanner.scan(/\=/)
            @lex_state = :expr_beg
            return [:tOP_ASGN, result]
          end

          if @lex_state == :expr_cmdarg || @lex_state == :expr_arg
            if !scanner.check(/\s/) && @space_seen
              @lex_state = :expr_mid
              return [sign, sign]
            end
          end

          @lex_state = :expr_beg
          return [result, result]

        elsif scanner.scan(/\?/)
          if end?
            @lex_state = :expr_beg
            return :tEH, scanner.matched
          end

          unless scanner.check(/\ |\t|\r|\s/)
            @lex_state = :expr_end
            return :tSTRING, scanner.scan(/./)
          end

          @lex_state = :expr_beg
          return :tEH, scanner.matched

        elsif scanner.scan(/\~/)
          if @lex_state == :expr_fname
            @lex_state = :expr_end
            return :tTILDE, '~'
          end
          @lex_state = :expr_beg
          return :tTILDE, '~'

        elsif scanner.check(/\$/)
          if scanner.scan(/\$([1-9]\d*)/)
            @lex_state = :expr_end
            return :tNTH_REF, scanner.matched.sub('$', '')

          elsif scanner.scan(/(\$_)(\w+)/)
            @lex_state = :expr_end
            return :tGVAR, scanner.matched

          elsif scanner.scan(/\$[\+\'\`\&!@\"~*$?\/\\:;=.,<>_]/)
            @lex_state = :expr_end
            return :tGVAR, scanner.matched
          elsif scanner.scan(/\$\w+/)
            @lex_state = :expr_end
            return :tGVAR, scanner.matched
          else
            raise "Bad gvar name: #{scanner.peek(5).inspect}"
          end

        elsif scanner.scan(/\$\w+/)
          @lex_state = :expr_end
          return :tGVAR, scanner.matched

        elsif scanner.scan(/\@\@\w*/)
          @lex_state = :expr_end
          return :tCVAR, scanner.matched

        elsif scanner.scan(/\@\w*/)
          @lex_state = :expr_end
          return :tIVAR, scanner.matched

        elsif scanner.scan(/\,/)
          @lex_state = :expr_beg
          return ',', scanner.matched

        elsif scanner.scan(/\{/)
          if @start_of_lambda
            @start_of_lambda = false
            @lex_state = :expr_beg
            return [:tLAMBEG, scanner.matched]

          elsif [:expr_end, :expr_arg, :expr_cmdarg].include? @lex_state
            result = :tLCURLY
          elsif @lex_state == :expr_endarg
            result = :LBRACE_ARG
          else
            result = '{'
          end

          @lex_state = :expr_beg
          cond_push 0
          cmdarg_push 0
          return result, scanner.matched

        elsif scanner.check(/[0-9]/)
          @lex_state = :expr_end
          if scanner.scan(/0b?(0|1|_)+/)
            return [:tINTEGER, scanner.matched.to_i(2)]
          elsif scanner.scan(/0o?([0-7]|_)+/)
            return [:tINTEGER, scanner.matched.to_i(8)]
          elsif scanner.scan(/[\d_]+\.[\d_]+\b|[\d_]+(\.[\d_]+)?[eE][-+]?[\d_]+\b/)
            return [:tFLOAT, scanner.matched.gsub(/_/, '').to_f]
          elsif scanner.scan(/[\d_]+\b/)
            return [:tINTEGER, scanner.matched.gsub(/_/, '').to_i]
          elsif scanner.scan(/0(x|X)(\d|[a-f]|[A-F]|_)+/)
            return [:tINTEGER, scanner.matched.to_i(16)]
          else
            raise "Lexing error on numeric type: `#{scanner.peek 5}`"
          end

        elsif scanner.scan(/(\w)+[\?\!]?/)
          return process_identifier scanner.matched, cmd_start
        end

        if scanner.eos?
          if @scanner_stack.size == 1 # our main scanner, we cant pop this
            return [false, false]
          else # we were probably parsing a heredoc, so pop that parser and continue
            @scanner_stack.pop
            @scanner = @scanner_stack.last
            return next_token
          end
        end

        raise "Unexpected content in parsing stream `#{scanner.peek 5}` :#{@file}:#{@line}"
      end
    end
  end
end
