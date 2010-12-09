require 'rubygems'
require 'eventmachine'
require 'eventmachine-tail'
require 'rrd'
require 'logger'
require 'erb'

module LogTrend
  class Base
    # This sets the directory where graphs should be stored.
    attr_accessor :graphs_dir

    # This sets the directory where your RRD files will rest.
    attr_accessor :rrd_dir
  
    def initialize
      @graphs_dir = '.'
      @rrd_dir = '.'
      @trends = {}
      @graphs = []
      @logger = Logger.new(STDERR)
      @logger.level = ($DEBUG and Logger::DEBUG or Logger::WARN)
      
      @template = ERB.new <<-EOF
      <html>
        <head>
          <title>logtrend</title>
        </head>
        <body>
          <% @graphs.each do |graph| %>
            <img src='<%=graph.name%>.png' />
          <% end %>
        </body>
      </html>
      EOF
    end

    def add_trend(name, &block)
      throw "D'oh! No block." unless block_given?
      @trends[name] = block
    end

    def add_graph(name, &block)
      throw "D'oh! No block." unless block_given?
      graph = Graph.new(name)
      yield graph
      @graphs << graph
    end
    #
    # This is the preferred entry point.
    def self.run(logfile, &block)
      throw "D'oh! No block." unless block_given?
      l = Base.new
      yield l
      l.run logfile
    end

    def run(logfile)
      counters = reset_counters

      EventMachine.run do
        EventMachine::add_periodic_timer(1.minute) do
          @logger.debug "#{Time.now} #{counters.inspect}"
          counters.each {|name, value| update_rrd(name, value)}
          @graphs.each {|graph| build_graph(graph)}
          build_page
          counters = reset_counters
        end

        EventMachine::file_tail(logfile) do |filetail, line|
          @trends.each do |name, block|
            counters[name] += 1 if block.call(line)
          end
          @logger.debug counters.inspect
        end
      end
    end

    private

    def reset_counters
      counters = {}
      @trends.keys.each do |k|
        counters[k] = 0
      end
      counters
    end

    def update_rrd(name, value)
      file_name = File.join(@rrd_dir,"#{name}.rrd")
      rrd = RRD::Base.new(file_name)
      if !File.exists?(file_name)
        rrd.create :start => Time.now - 10.seconds, :step => 1.minutes do
          datasource "#{name}_count", :type => :gauge, :heartbeat => 5.minutes, :min => 0, :max => :unlimited
          archive :average, :every => 5.minutes, :during => 1.year
        end
      end
      rrd.update Time.now, value
    end

    def build_graph(graph)
      rrd_dir = @rrd_dir
      RRD.graph File.join(@graphs_dir,"#{graph.name}.png"), :title => graph.name, :width => 800, :height => 250, :color => ["FONT#000000", "BACK#FFFFFF"] do
        graph.points.each do |point|
          if point.style == :line
            line File.join(rrd_dir,"#{point.name}.rrd"), "#{point.name}_count" => :average, :color => point.color, :label => point.name.to_s
          elsif point.style == :area
            area File.join(rrd_dir,"#{point.name}.rrd"), "#{point.name}_count" => :average, :color => point.color, :label => point.name.to_s
          end
        end
      end
    end

    def build_page
      file_name = File.join(@graphs_dir,'index.html')
      File.open(file_name, "w") do |f|
        f << @template.result(binding)
      end
    end
    
  end

  class Graph

    attr_reader :points
    attr_reader :name

    def initialize(name)
      @name = name
      @points = []
    end

    def add_point(style,name,color)
      @points << GraphPoint.new(style, name, color)
    end
  end

  GraphPoint = Struct.new(:style, :name, :color)
end
