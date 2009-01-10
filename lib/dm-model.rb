class Solution
  include DataMapper::Resource

  property :id, Serial
  timestamps :created_at, :updated_at
  property :parameters, Object, :length => 0..1000, :lazy => false, :default => {}
  property :data, Object, :length => 0..1_000_000, :default => {}
  property :errors, Object, :length => 0..1_000_000, :default => []
  property :url_hash, String, :length => 40, :default => Proc.new { |r,p| Digest::SHA1.hexdigest((r.parameters['name'] || '').to_s + (r.parameters['email'] || '').to_s + (r.created_at || DateTime.now).to_s) }
  property :processing, Boolean, :default => false

  is :state_machine, :initial => :new, :column => :state do
    state :new, :exit => :initialize_data
    state :downloaded, :enter => :download #, :exit => ...
    state :cleaned, :enter => :clean
    state :computed, :enter => :compute
    state :generated, :enter => :generate

    event :reset do
      transition :from => :new, :to => :new
      transition :from => :downloaded, :to => :new
      transition :from => :cleaned, :to => :new
      transition :from => :computed, :to => :new
      transition :from => :generated, :to => :new
    end

    event :download do
      transition :from => :new, :to => :downloaded
    end

    event :clean do
      transition :from => :downloaded, :to => :cleaned
    end

    event :compute do
      transition :from => :cleaned, :to => :computed
    end

    event :generate do
      transition :from => :computed, :to => :generated
    end
  end

  def solve!
    __i = 5
    p 'entered'
    return if processing
    p 'next'
    #return if state == 'generated'
    begin
      p 'started'
      self.processing = true; self.save
      p 'started & saved'
      self.reset!     #; self.save
      p 'resetted'
      self.download!  #; self.save
      p 'downloaded'
      self.clean!     #; self.save
      p 'cleaned'
      self.compute!   #; self.save
      p 'computed'
      self.generate!  #; self.save
      p 'generated'
      self.processing = false; self.save
      p 'saved'
    rescue Sqlite3Error
      print "Sqlite3Error -> retry (#{6-__i})\n"
      __i -= 1
      sleep 2
      retry if __i > 0
      raise
    end
  rescue
    print "Unrecoverable error: #{$!.message} (#{$!.class})\n#{$!.backtrace.join("\n")}\n"
    self.errors << { :exception => $!.class, :message => $!.message, :backtrace => $!.backtrace, :occured_at => DateTime.now }
    self.processing = false; self.save
  end

  def initialize_data
    data[:stocks] = []
    data[:indices] = []
    data[:currencies] = []
    data[:portfolios] = []
  end

  def download
    # Portfolióban résztvevő részvények
    parameters[:stocks].each do |i,w|
      next if i.nil? or i == 0
      name, start_date, end_date, data = request_stock_data_from_portfolio(i, parameters[:start], parameters[:end]) rescue next
      s = Stock.new(name, start_date, end_date, i)
      s.import_data_from(data)
      self.data[:stocks] << s
    end

    # indexek (most csak a BUX)
    1.times do
      name, start_date, end_date, data = request_index_data_from_portfolio(392, parameters[:start], parameters[:end]) rescue next
      i = Index.new(name, start_date, end_date, 392)
      i.import_data_from(data)
      self.data[:indices] << i
    end

    # valuták
    parameters[:currencies].each do |i| # Ft és a valuta
      name, start_date, end_date, data = request_currency_data_from_portfolio(i, parameters[:start], parameters[:end]) rescue next
      c = Currency.new(name, start_date, end_date, i)
      c.import_data_from(data)
      self.data[:currencies] << c
    end
  end

  def clean
    self.data[:stocks].each { |s| s.flatten_data_by(self.data[:indices][0]) }

    # Saját portfóliónk (mindegyik részvény 1-1 egységgel vesz részt a portfólióban)
    # TODO: ezt itt lehetne még egy kicsit megtámogatni, hogy a feladat többmindenre legyen alkalmas
    self.data[:portfolios] << Portfolio.new(self.data[:stocks].map { |s| [ s, parameters[:stocks].find{|e| e[0]==s.id}[1] || 1.0 ] }, parameters[:start], parameters[:end])
    #                                                                         ^^ ez itt arra szolgál, hogy az eredeti súlyt megtalálja a Stock#id alapján a paraméterek között
  end

  def compute # TODO: generalize
    bux = self.data[:indices].first
    cur = self.data[:currencies].last

    # devizával kapcsolatos számítások
    cur.compute_base_indices
    cur.compute_yields
    cur.compute_mean_for(:all)
    cur.compute_standard_deviation_for(:all)
    cur.compute_variance_for(:all)

    # BUX-szal kapcsolatos számítások
    bux.compute_base_indices
    bux.compute_base_indices_with_currency(cur)
    bux.compute_yields
    bux.compute_log_yields
    #bux.compute_yields_with_currency(cur)
    bux.compute_cumulated_log_yields
    bux.compute_mean_for(:all)
    bux.compute_standard_deviation_for(:all)
    bux.compute_variance_for(:all)

    # Részvényekkel kapcsolatos számítások
    self.data[:stocks].each do |s|
      s.compute_base_indices
      s.compute_base_indices_deflated_by(bux)
      s.compute_base_indices_with_currency(cur)
      s.compute_base_indices_with_currency_deflated_by(cur, bux)
      s.compute_yields
      s.compute_log_yields
      #s.compute_yields_with_currency(cur)
      s.compute_cumulated_log_yields
      s.compute_mean_for(:all)
      s.compute_standard_deviation_for(:all)
      s.compute_variance_for(:all)
      #s.compute_covariance_with(bux, [ :c, :b, :b_usd, :l, :y ])
      #s.compute_beta_on(bux, [ :c, :b, :b_usd, :l, :y ])
      #s.compute_systematic_risk_on(bux, [ :c, :b, :b_usd, :l, :y ])
      #s.compute_non_systematic_risk_on(bux, [ :c, :b, :b_usd, :l, :y ])
      s.compute_covariance_with(bux, [ :y ])
      s.compute_beta_on(bux, [ :y ])
      s.compute_systematic_risk_on(bux, [ :y ])
      s.compute_non_systematic_risk_on(bux, [ :y ])
    end

    optimized_portfolios = []
    # Portfoliókkal kapcsolatos számítások
    self.data[:portfolios].each do |p|
      # Idősor adatok
      p.compute_base_indices
      p.compute_base_indices_deflated_by(bux)
      p.compute_base_indices_with_currency(cur)
      p.compute_base_indices_with_currency_deflated_by(cur, bux)
      p.compute_yields
      p.compute_log_yields
      #p.compute_yields_with_currency(cur)
      p.compute_cumulated_log_yields

      # Aggregált adatok
      p.compute_mean_for(:all)
      p.compute_standard_deviation_for(:all)
      p.compute_variance_for(:all)

      # Kovariancia és béta
      #p.compute_covariance_with(bux, [ :c, :b, :b_usd, :l, :cl, :y ])
      #p.compute_covariance_matrix_for([ :c, :y ])
      #p.compute_beta_on(bux, [ :c, :b, :b_usd, :l, :cl, :y ])
      p.compute_covariance_with(bux, [ :y ])
      p.compute_covariance_matrix_for([ :y ])
      p.compute_beta_on(bux, [ :y ])

      # Portfolió kockázata
      #p.compute_systematic_risk_on(bux, [ :c, :b, :b_usd, :l, :cl, :y ])
      #p.compute_non_systematic_risk_on(bux, [ :c, :b, :b_usd, :l, :cl, :y ])
      p.compute_systematic_risk_on(bux, [ :y ])
      p.compute_non_systematic_risk_on(bux, [ :y ])

      # Minimalizálási feladat
      if defined?(GSL)
        p.compute_minimum_non_systematic_risk_on(bux, [ :y ])
      end

      optimized_portfolios << Portfolio.new(p.aggregates[:y][:w_min].map { |k,v| [ p.sources.to_a.inject({}) { |h,ss| h.merge(ss[0].name.to_s.upcase => ss[0]) }[k.to_s.upcase], v ]}, parameters[:start], parameters[:end], "opt_y")

      ## Erre alapvetően nincs szükség, de el lehetne készíteni így is :)
      ## # Kovariancia-mátrix számítása, majd abból a portfólió szórása
      ## p.compute_covariance_matrix_for(:c)
      ## p.compute_variance_by_covariance_matrix_for(:c)
    end

    optimized_portfolios.each do |p|
      # Idősor adatok
      p.compute_base_indices
      p.compute_base_indices_deflated_by(bux)
      p.compute_base_indices_with_currency(cur)
      p.compute_base_indices_with_currency_deflated_by(cur, bux)
      p.compute_yields
      p.compute_log_yields
      #p.compute_yields_with_currency(cur)
      p.compute_cumulated_log_yields

      # Aggregált adatok
      p.compute_mean_for(:all)
      p.compute_standard_deviation_for(:all)
      p.compute_variance_for(:all)

      # Kovariancia és béta
      #p.compute_covariance_with(bux, [ :c, :b, :b_usd, :l, :cl, :y ])
      #p.compute_beta_on(bux, [ :c, :b, :b_usd, :l, :cl, :y ])
      p.compute_covariance_with(bux, [ :y ])
      p.compute_beta_on(bux, [ :y ])

      # Portfolió kockázata
      #p.compute_systematic_risk_on(bux, [ :c, :b, :b_usd, :l, :cl, :y ])
      #p.compute_non_systematic_risk_on(bux, [ :c, :b, :b_usd, :l, :cl, :y ])
      p.compute_systematic_risk_on(bux, [ :y ])
      p.compute_non_systematic_risk_on(bux, [ :y ])

      # # Minimalizálási feladat
      # if defined?(GSL)
      #   p.compute_minimum_non_systematic_risk_on(bux, [ :c, :b, :b_usd, :l, :cl, :y ])
      # end

      ## Erre alapvetően nincs szükség, de el lehetne készíteni így is :)
      ## # Kovariancia-mátrix számítása, majd abból a portfólió szórása
      ## p.compute_covariance_matrix_for(:c)
      ## p.compute_variance_by_covariance_matrix_for(:c)
    end
    self.data[:portfolios] += optimized_portfolios

    #self.data[:stocks].first.ordinals.to_a.sort[100...105].each { |d,v| print "#{d.to_s}: #{v.inspect}\n" }
    #self.data[:stocks].first.aggregates.each { |k,v| print "#{k.inspect}: #{v.inspect}\n" }
    #self.data[:stocks].each { |s| s.ordinals.to_a.sort[100].each { |v| print "#{v.inspect}\n" } }
    #self.data[:portfolios].first.ordinals.to_a.sort[100].each { |v| print "#{v.inspect}\n" }
    #self.data[:portfolios].each { |p| p p.name.to_sym }
    #self.data[:portfolios].first.aggregates.each { |k,v| print "#{k.inspect}: #{v.inspect}\n" }
    #self.data[:stocks].first.aggregates.each { |k,v| print "#{k.inspect}: #{v.inspect}\n" }
    #self.data[:portfolios].first.aggregates.each { |k,v| print "#{k.inspect}: #{v.inspect}\n" }
    #p self.data[:stocks].first.aggregates[:c]
    #p self.data[:portfolios].first.aggregates[:c]
    #p self.data[:indices].first.ordinals.to_a.first
    #p self.data[:portfolios].first.aggregates.keys
    #p self.data[:portfolios].map{ |p| [ p.name, p.aggregates[:y] ] }
    #p self.data[:portfolios].map{ |p| [ p.name, p.aggregates[:c] ] }
    #self.data[:stocks].first.ordinals.to_a.sort[100...105].each { |d,v| print "#{d.to_s}: #{v.inspect}\n" }
    #p self.data[:portfolios].first.aggregates[:y][:w_min]
  end

  def generate
    image_dir = "#{SINATRA_ROOT}/public/images/#{self.url_hash}"
    [ File.dirname(image_dir), image_dir ].each { |dir_path| Dir.mkdir(dir_path) rescue nil }

    select_point_markers = lambda do |ordinal_data|
      case ordinal_data.size
      when 0
      when 1...10
        # minden napot ki lehet írni
      when 10...50
        # évek és hónapok
      when 40...1_000
        # évek
        days = ordinal_data.keys.sort
        days_6 = days.size / 6
        ret  = []
        # or i == days.size-1
        days.each_with_index { |d,i| ret << ((i % days_6 == 0) ? "#{d.month(:hu_HU)} #{'%02d' % d.day}\n#{d.year}" : "") }
        ret
      when 1_000...1_000_000
        # nemtom
      end
    end

    # záró indexek (együtt)
    g                 = Scruffy::Graph.new
    g.title           = 'Záró indexek (összes)'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 1)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:indices]).each do |o|
      g.add :area, o.name, o.export_a(:c)
    end
    (self.data[:stocks]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:c)
    end
    #(self.data[:stocks] + self.data[:portfolios]).each do |o|
    #  g.add :line_without_dots, o.name, o.export_a(:c)
    #end
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/close_indices_all.png", :as => "png", :width => 800

    # záró indexek (portfólió)
    g                 = Scruffy::Graph.new
    g.title           = 'Portfólió indexek'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 1)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:portfolios][0..0]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:c)
    end
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/close_indices_p.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # bázis indexek (együtt)
    g                 = Scruffy::Graph.new
    g.title           = 'Bázisindexek'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:indices] + self.data[:stocks] + self.data[:portfolios][0..0]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:b)
    end
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/base_indices_all.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # bázis indexek (részvények)
    g                 = Scruffy::Graph.new
    g.title           = 'Bázisindexek (részvények)'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:indices] + self.data[:stocks]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:b)
    end
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/base_indices_i_s.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # bázis indexek (részvények)
    g                 = Scruffy::Graph.new
    g.title           = 'Bázisindexek (portfóliók)'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:indices] + self.data[:portfolios][0..0]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:b)
    end
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/base_indices_i_p.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # deflált bázis indexek (együtt)
    g                 = Scruffy::Graph.new
    g.title           = 'Deflált bázisindexek'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
    g.renderer        = Scruffy::Renderers::Standard.new
    g.add :line_without_dots, self.data[:indices].first.name, [1.0]*self.data[:indices].first.ordinals.size
    self.data[:stocks].each do |o|
      g.add :line_without_dots, o.name, o.export_a(:b_bux)
    end
    (self.data[:portfolios][0..0]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:b_bux)
    end
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/deflated_base_indices_all.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # deflált bázis indexek (részvények)
    g                 = Scruffy::Graph.new
    g.title           = 'Deflált bázisindexek'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
    g.renderer        = Scruffy::Renderers::Standard.new
    g.add :line_without_dots, self.data[:indices].first.name, [1.0]*self.data[:indices].first.ordinals.size
    (self.data[:stocks]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:b_bux)
    end
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/deflated_base_indices_s.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # deflált bázis indexek (portfóliók)
    g                 = Scruffy::Graph.new
    g.title           = 'Deflált bázisindexek'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
    g.renderer        = Scruffy::Renderers::Standard.new
    g.add :line_without_dots, self.data[:indices].first.name, [1.0]*self.data[:indices].first.ordinals.size
    (self.data[:portfolios][0..0]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:b_bux)
    end
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/deflated_base_indices_p.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # deflált és deflálatlan bázisindexek (részvényenként)
    (self.data[:stocks]+self.data[:portfolios][0..0]).each do |o|
      g                 = Scruffy::Graph.new
      g.title           = "Deflálatlan és BUX értékével deflált bázisindexek (#{o.name.upcase})"
      g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
      g.renderer        = Scruffy::Renderers::Standard.new
      g.add :line_without_dots, "#{o.name} deflálatlan", o.export_a(:b)
      g.add :line_without_dots, "#{o.name} deflált", o.export_a(:b_bux)
      g.add :line_without_dots, '1.0', [1.0]*self.data[:indices].first.ordinals.size
      g.point_markers   = select_point_markers.call( o.ordinals )
      g.render :to => "#{image_dir}/simple_and_deflated_base_indices_#{o.name.downcase.gsub('+','_')}.png", :as => "png", :width => 800, :min_value => g.bottom_value
    end

    # deviza alakulása
    g                 = Scruffy::Graph.new
    g.title           = "Deviz#{self.data[:currencies] == 2 ? 'a' : 'ák'} alakulása"
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 1)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:currencies][1..-1]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:c)
    end
    g.add :line_without_dots, 'bázis', [self.data[:currencies][1].export_a(:c).first]*self.data[:indices].first.ordinals.size
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/currencies_all.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # deviza alakulása (bázisban)
    g                 = Scruffy::Graph.new
    g.title           = "Deviz#{self.data[:currencies].size == 2 ? 'a' : 'ák'} alakulása (bázis)"
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:currencies][1..-1]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:b)
    end
    g.add :line_without_dots, self.data[:currencies].first.name, [1.0]*self.data[:indices].first.ordinals.size
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/currencies_base_all.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # devizával módosított bázis indexek (együtt)
    g                 = Scruffy::Graph.new
    g.title           = 'Külföldi befektető alapján számolt bázisindexek'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:indices] + self.data[:stocks] + self.data[:portfolios][0..0]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:b_usd)
    end
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/base_indices_for_foreigns_all.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # devizával módosított bázis indexek (részvényekre)
    g                 = Scruffy::Graph.new
    g.title           = 'Külföldi bef...bázisindexek (részvényekre)'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:indices] + self.data[:stocks]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:b_usd)
    end
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/base_indices_for_foreigns_i_s.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # devizával módosított bázis indexek (portfóliókra)
    g                 = Scruffy::Graph.new
    g.title           = 'Külföldi bef...bázisindexek (portfóliókra)'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:indices] + self.data[:portfolios][0..0]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:b_usd)
    end
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/base_indices_for_foreigns_i_p.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # devizával módosított deflált bázisindexek (együtt)
    g                 = Scruffy::Graph.new
    g.title           = 'Külföldi befektető alapján számolt deflált bázisindexek'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:stocks] + self.data[:portfolios][0..0]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:b_usd_bux)
    end
    g.add :line_without_dots, '1.0', [1.0]*self.data[:indices].first.ordinals.size
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/deflated_base_indices_for_foreigns_all.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # devizával módosított deflált bázisindexek (részvényenként)
    g                 = Scruffy::Graph.new
    g.title           = 'Külföldi...deflált bázisindexek (részvényekre)'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:stocks]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:b_usd_bux)
    end
    g.add :line_without_dots, '1.0', [1.0]*self.data[:indices].first.ordinals.size
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/deflated_base_indices_for_foreigns_s.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # devizával módosított deflált bázisindexek (portfólióra)
    g                 = Scruffy::Graph.new
    g.title           = 'Külföldi...deflált bázisindexek (portfóliókra)'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:portfolios][0..0]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:b_usd_bux)
    end
    g.add :line_without_dots, '1.0', [1.0]*self.data[:indices].first.ordinals.size
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/deflated_base_indices_for_foreigns_p.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # devizával módosított deflált és deflálatlan bázisindexek (részvényenként)
    (self.data[:stocks]+self.data[:portfolios][0..0]).each do |o|
      g                 = Scruffy::Graph.new
      g.title           = "Külföldi...deflálatlan és deflált bázisindexek (#{o.name.upcase})"
      g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
      g.renderer        = Scruffy::Renderers::Standard.new
      g.add :line_without_dots, "#{o.name}d0h", o.export_a(:b)
      g.add :line_without_dots, "#{o.name}d1h", o.export_a(:b_bux)
      g.add :line_without_dots, "#{o.name}d0u", o.export_a(:b_usd)
      g.add :line_without_dots, "#{o.name}d1u", o.export_a(:b_usd_bux)
      g.add :line_without_dots, '1.0', [1.0]*self.data[:indices].first.ordinals.size
      g.point_markers   = select_point_markers.call( o.ordinals )
      g.render :to => "#{image_dir}/simple_and_deflated_base_indices_for_foreigns_#{o.name.downcase.gsub('+','_')}.png", :as => "png", :width => 800, :min_value => g.bottom_value
    end

    # hozam ábrák (együtt)
    g                 = Scruffy::Graph.new
    g.title           = 'Hozamok (%)'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 1)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:indices] + self.data[:stocks] + self.data[:portfolios][0..0]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:y)
    end
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/yields_all.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # hozamok külön
    g                 = Scruffy::Graph.new
    g.title           = 'Hozam részvényekre (%)'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 1)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:indices] + self.data[:stocks]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:y)
    end
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/yields_i_s.png", :as => "png", :width => 800, :min_value => g.bottom_value

    g                 = Scruffy::Graph.new
    g.title           = 'Hozam portfóliókra (%)'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 1)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:indices] + self.data[:portfolios][0..0]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:y)
    end
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/yields_i_p.png", :as => "png", :width => 800, :min_value => g.bottom_value

    # napi loghozam hisztogramok
    (self.data[:indices] + self.data[:stocks] + self.data[:portfolios][0..0]).each do |o|
      g                 = Scruffy::Graph.new
      g.title           = 'Napi loghozamok'
      g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
      g.renderer        = Scruffy::Renderers::Standard.new
      g.add :histogram, o.name, o.export_a(:l)
      g.point_markers   = select_point_markers.call( o.ordinals )
      g.render :to => "#{image_dir}/log_yields_#{o.name.downcase.gsub('+','_')}.png", :as => "png", :width => 800, :min_value => -([g.bottom_value.abs, g.top_value.abs].max), :max_value => [g.bottom_value.abs, g.top_value.abs].max
    end

    # napi kumulált loghozam grafikonok
    (self.data[:indices] + self.data[:stocks] + self.data[:portfolios][0..0]).each do |o|
      g                 = Scruffy::Graph.new
      g.title           = 'Napi kumulált loghozamok (bázisindexek logaritmusai)'
      g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
      g.renderer        = Scruffy::Renderers::Standard.new
      g.add :line_without_dots, o.name, o.export_a(:cl)
      g.point_markers   = select_point_markers.call( o.ordinals )
      g.render :to => "#{image_dir}/cumulated_log_yields_#{o.name.downcase.gsub('+','_')}.png", :as => "png", :width => 800, :min_value => g.bottom_value
    end

    g                 = Scruffy::Graph.new
    g.title           = 'Napi kumulált loghozamok (bázisindexek logaritmusai)'
    g.value_formatter = Scruffy::Formatters::Number.new(:separator => ',', :delimiter => ' ', :precision => 3)
    g.renderer        = Scruffy::Renderers::Standard.new
    (self.data[:indices] + self.data[:stocks] + self.data[:portfolios][0..0]).each do |o|
      g.add :line_without_dots, o.name, o.export_a(:cl)
    end
    g.point_markers   = select_point_markers.call( self.data[:indices].first.ordinals )
    g.render :to => "#{image_dir}/cumulated_log_yields_all.png", :as => "png", :width => 800, :min_value => g.bottom_value

  end
end

