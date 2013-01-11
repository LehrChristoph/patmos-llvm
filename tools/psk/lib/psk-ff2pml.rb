#!/usr/bin/env ruby
#
# Converts SWEET .ff files to PML format
#
# TODO: port to python or C++ (to reduce number of languages)
# TODO: support a larger variety of flow facts (call strings, loop contexts)

require 'yaml'
require 'ostruct'
require 'optparse'
begin
  require 'rubygems'
  require 'rsec'
  include Rsec::Helpers
rescue => details
  $stderr.puts "Failed to load library rsec (gem install rsec)"
  raise details
end

# Edge between basic blocks
class Edge
  def initialize(src,target)
    @src, @target = src, target
  end
  def to_s
    "#{@src}->#{@target}"
  end
end

# Callstring
class Callstring
  # ctx := [ caller, callstmt, callee ] *
  attr_reader :ctx
  def initialize(callstack)
    @ctx = callstack
  end
  def empty?
    @ctx.empty?
  end
  def to_s
    @ctx.map { |site| site.join(", ") }.join("  |  ")
  end
end

# Context
class Context
  attr_reader :f,:stmt
  def initialize(func,stmt=nil)
    @f,@stmt = func,stmt
  end
  def to_s
    if @stmt
      "(#{f}, #{stmt})"
    else
      "#{f}"
    end
  end
end

# Vector (Linear combination of edge frequency variables)
class Vector
  attr_reader :vec, :const
  def initialize
    @vec, @const = Hash.new(0), 0
  end
  def add(coeff,r)
    if r
      @vec[r] += coeff
    else
      @const  += coeff
    end
  end
  def Vector.negate(vec)
    vneg = {}
    vec.each do |k,v|
      vneg[k] = -v
    end
    vneg
  end
  def Vector.subtract!(v1,v2)
    v2.each do |v,coeff|
      v1[v] -= coeff
    end
    v1
  end
  def to_s
    return const.to_s if @vec.empty?
    s = @vec.map { |v,coeff|
      if coeff == 1
        v
      else
        "#{coeff} * #{v}"
      end
    }.join(" + ")
    s << " + #{const}" if(@const!=0)
    s
  end
end

# Constraint
class Constraint
  # vector: (var x coeff) list
  # op: <= | =
  # rhs: int
  attr_reader :vector, :op, :rhs
  def initialize(lhs,op,rhs)
    @rhs     = rhs.const - lhs.const
    @vector  = Vector.subtract!(lhs.vec, rhs.vec)
    @op      = op
    if(op == '<')
      @op, @rhs = "<=", @rhs+1
    elsif(op == '>')
      @op, @rhs = '>=', @rhs-1
    end
    if(op == ">=")
      @op, @vector, @rhs = '<=', -@rhs, Vector.negate(@vector)
    end
  end
  def vars
    @vector.map { |var,coeff| var }
  end
  def to_s
    lhs = @vector.map { |var,coeff|
      if coeff != 1
        "#{coeff} * #{var}"
      else
        var.to_s
      end
    }.join(" + ")
    "#{lhs} #{op} #{rhs}"
  end
end

# Flowfact (SWEET format)
class FlowFact
  attr_reader :type, :callstring, :scope, :quantifier, :constraint
  def initialize(type, cs,scope,quant,constraint)
    @type, @callstring, @scope, @quantifier, @constraint = type, cs, scope, quant, constraint
  end
  def to_pml
    raise Exception.new("loop scopes not yet supported") if @quantifier != :total
    raise Exception.new("loop scopes not yet supported") if @scope.stmt
    raise Exception.new("call strings not yet supported") unless @callstring.empty?
    ff = {}
    ff["level"] = "bitcode"
    ff['origin'] = "sweet"
    ff["scope"] = @scope.f
    ff["lhs"]   = @constraint.vector.map { |pnt,factor|
      { "factor" => factor, "program-point" => pp_to_pml(pnt)  }
    }
    ff["op"]    =
      case @constraint.op
      when "<="; "less-equal"
      when "=" ; "equal"
      else     ; raise Exception.new("Bad constraint op: #{@constraint.op}")
      end
    ff["rhs"]   = @constraint.rhs
    ff
  end
  def pp_to_pml(pp)
    raise Exception.new("edge program points not yet supported") if pp.kind_of?(Edge)
    llvm,internal = pp.split(":::")
    fun,block,ins = llvm.split("::")
    # For upper bounds, we could ignore the internal structure of the block
    raise Exception.new("translation internal program points not supported") if internal
    raise Exception.new("instruction program points not supported") if ins
    { "function" => fun, "block" => block }
  end
end


# Parse SWEETs flow fact format using the Rsec parser
# combinator library
class SWEETFlowFactParser

  def flowfact(as)
    FlowFact.new(*as)
  end

  def paren(p,left='(',right=')')
    left.r >> p << right.r
  end
  def sym(c)
    symbol(c.r)
  end

  def int
    /\d+/.r.map { |v| v.to_i }
  end
  def stmt
    /[^:*+\-;,() \s\d]([^:;,() \s*+\-]|:::?)*/.r
  end
  def func
    stmt
  end
  def callstring
    caller = paren(seq_(func,stmt, skip: sym(',')))
    call   = paren(seq_(caller,func, skip: sym(',')))
    (call << /\s*/.r).star.map { |cs| Callstring.new(cs.map { |c| c.flatten }) }
  end
  def context
    paren(seq_(func,stmt,skip: sym(','))).map { |xs| Context.new(*xs) } |
      func.map { |xs| Context.new(xs) }
  end
  def quantifier
    range   = seq_(int,'..'.r,int).map { |lb,_,ub| [lb,ub] }
    foreach = paren(range.maybe,'<','>').map { |p| if(p.empty?) then :foreach else p.first end }
    total   =  ( symbol('[') << symbol(']') ).map { :total }
    quantifier = foreach | total
  end
  def build_vector
    proc do |p,*ps|
      sum = Vector.new
      sum.add(*p)
      ps.each_slice(2) do |(op, (coeff,var))|
        if(op=='-')
          sum.add(-coeff,var)
        elsif(op=='+')
          sum.add(coeff,var)
        else
          raise Exception.new("Bad addop: #{op}")
        end
      end
      sum
    end
  end
  def constraint
    expr = sym /([^<>= -]|->)+/
    count_var = seq(stmt,('->'.r >> stmt).maybe).map { |c| c[1].empty? ? c[0] : Edge.new(c[0],c[1].first) }
    cvar  = seq_( (symbol(int) << sym('*')).maybe.map { |f| f.empty? ? 1 : f.first }, count_var)
    mexpr = cvar | int.map { |p| [p,nil] }
    addop = one_of_("+-")
    expr = mexpr.join(addop).map(&build_vector)
    comparator = sym /[<>]=?|=/
    seq_(expr,comparator,expr).map { |as| Constraint.new(*as) }
  end
  def parser
    ff = seq_(callstring, context, quantifier, constraint, skip: sym(':')) << ";".r
    ff_comment = seq_(ff,sym('%%')>>/\w{4}/.r).map { |((cs,ctx,quant,constr),type)|
      FlowFact.new(type,cs,ctx,quant,constr)
    }
  end
end

# Standard option parser
options = OpenStruct.new
parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [-i facts.pml] -o facts.pml facts.ff"
  opts.on("-o", "--output FILE", "Output File") { |f| options.output = f }
  opts.on("-i", "--input FILE", "Extend this PML file") { |f| options.input = f }
  opts.on_tail("-h", "--help", "Show this message") { $stderr.puts opts; exit 0 }
end.parse!
if options.replace && options.input then $stderr.puts "Options --input and --replace conflict. Try --help"; exit 1; end
if ARGV.length > 1 then $stderr.puts "Wrong number of arguments. Try --help" ; exit 1 ; end

# input/output
infile   = if ARGV.first
            File.open(ARGV[0])
          else
            $stdin
          end
data = if(options.input)
         YAML::load(File.read(options.input))
       else
         {}
       end
outfile = if ! options.output || options.output == "-"
            $stdout
          else
            File.open(options.output,"w")
          end

# parse
parser = SWEETFlowFactParser.new.parser
ffs = []
added, skipped, reasons, set = 0,0, Hash.new(0), {}
File.readlines(infile).map do |s|
  ff = parser.parse!(s)
  begin
    ff_pml = ff.to_pml
    if set[ff_pml]
      reasons["duplicate"] += 1
      skipped+=1
    else
      set[ff_pml] = true
      ffs.push(ff_pml)
      added += 1
    end
  rescue Exception=>detail
    reasons[detail.to_s] += 1
    skipped += 1
  end
end
data["flowfacts"] ||= []
data["flowfacts"].concat(ffs)
outfile.puts YAML::dump(data)
$stderr.puts "Parsed #{skipped+added} flow facts, added #{added}"
$stderr.puts "Reasons for skipping flow facts: "
reasons.each do |k,count|
  $stderr.puts "  #{k} (#{count})"
end
