begin
  require 'rbgsl'
rescue
  STDERR.print("Cannot load GSL, continuing without minimalization support...\n")
end

class Ordinal

  attr_reader :name, :start_date, :end_date, :ordinals, :aggregates, :id

  def initialize(name, start_date, end_date, id=nil)
    @id         = id
    @name       = name
    @start_date = start_date
    @end_date   = end_date

    @ordinals   = {}  # :c (záróár), :b (bázisindex),
                      # :b_bux (bázisindex bux-szal deflálva),
                      # :b_usd (bázisindex amerikai befektetőn keresztül),
                      # :b_usd_bux (bázisindex amerikai befektetőn keresztül bux-szal deflálva)
                      # :l (loghozam), :cl (kumulált loghozam)
                      # :y (hozam)

    @aggregates = {}  # :m (átlag), :s (szórás), :v (szórásnégyzet),
                      # :c_x (kovariancia egy másik adatsorral),
                      # :b_x (beta egy másik adatsor alapján)
                      # :cc (kovariancia mátrix -- portfolió esetén)
                      # :rs_x (szisztematikus kockázat == piaci kockázat, azaz a piac szórása * portfolió bétája; x tipikusan a piac :) )
                      # :rn_x (nem szisztematikus kockázat == egyedi kockázat, azaz a teljes gyök(szórásnégyzet - szisztematikus kockázat))
                      # :w_min ()
                      # :b_min (a minimális súlyok alapján számolt béta)
                      ### :s_cc (kovariancia mátrix alapján számolt szórás -- portfolió esetén)
                      ### :v_cc (kovariancia mátrix alapján számolt szórásnégyzet -- portfolió esetén)
  end

  # Importálja a portfolio.hu-ról származó adatokat
  def import_data_from(data)
    data.each { |day| @ordinals[day[:date]] = { :c => day[:close] } }
  end

  # Egy másik (tipikusan BUX) adatforrás alapján tisztítja az adatokat
  def flatten_data_by(source)
    actual = self.ordinals[self.ordinals.keys.sort.first]
    source.ordinals.keys.sort.each do |day|
      actual = (self.ordinals[day] ||= { :c => actual })[:c]
    end
  end

  # Napok sorrendben, tömbben
  def days
    @__days ||= @ordinals.keys.sort
  end

  #alias_method :original_method_missing, :method_missing
  #def method_missing(method_name, *args)
  #  original_method_missing(method_name, *args)
  #end

  # Az egyes záróárakat a kezdeti árral elosztva kapjuk meg az 
  # adott nap bázisindexét.
  # s_bázis(t) = s_záró(t) / s_záró(1)
  #   ahol s az adott részvény,
  #        t pedig az idő.
  def compute_base_indices
    base = ordinals[days.first][:c]
    ordinals.each { |day,values| values[:b] = values[:c] / base }
  end

#  # Hozamok számítása.
#  def compute_yields
#    previous = nil
#    base     = ordinals[days.first][:c]
#    days.each do |day|
#      values = ordinals[day]
#      values[:y] = (values[:c] / previous) * base if previous
#      previous = values[:c]
#    end
#  end

  # Hozamok számítása
  def compute_yields
    base     = ordinals[days.first][:c]
    days.each do |day|
      values = ordinals[day]
      values[:y] = ((values[:c] / base) - 1.0)*100.0
    end
  end

  # Loghozamok számítása.
  def compute_log_yields
    previous = nil
    days.each do |day|
      begin
        values = ordinals[day]
        values[:l] = Math.log(values[:c] / previous) if previous
      rescue Errno::EDOM
        values[:l] = 0.0
      ensure
        previous = values[:c]
      end
    end
  end

  # Kumulált loghozamok (amik egyébként a bázisindexek logaritmusai).
  def compute_cumulated_log_yields
    # sum = 0.0
    # days.each do |day|
    #   values = ordinals[day]
    #   values[:cl] = (sum += values[:l].to_f)
    # end
    ordinals.each do |day,values|
      begin
        values[:cl] = Math.log(values[:b])
      rescue Errno::EDOM
        values[:cl] = 0.0
      end
    end
  end

  def compute_call_for(types)
    types = ordinals.to_a.sort[1].last.keys if types==:all # az összesre végrehajtjuk, ha :all
    types = [ types ] unless types.is_a?(Array)
    types.each { |t| yield(t) }
  end
  protected :compute_call_for

  def compute_mean_for(types)
    compute_call_for(types) do |t|
      self.aggregates[t] ||= {}
      self.aggregates[t][:m] = export_a(t).mean
    end
  end

  def compute_standard_deviation_for(types)
    compute_call_for(types) do |t|
      mean = self.aggregates[t][:m]
      self.aggregates[t][:s] = export_a(t).sample_standard_deviation(mean)
    end
  end

  def compute_variance_for(types)
    compute_call_for(types) do |t|
      mean = self.aggregates[t][:m]
      self.aggregates[t][:v] = export_a(t).sample_variance(mean)
    end
  end

  # Amit kérünk, tömbben
  def export_a(sym)
    ret = []
    days.each { |day| ret << @ordinals[day][sym] }
    ret
  end

end

class Stock < Ordinal

  # s_deflált_bázis(t) = s_bázis(t) / i_bázis(t)
  #   ahol s az adott részvény,
  #        t pedig az idő.
  def compute_base_indices_deflated_by(index)
    sym = "b_#{index.name.downcase}".to_sym
    index_ordinals = index.ordinals
    ordinals.each { |day,values| values[sym] = values[:b] / index_ordinals[day][:b] }
  end

  def compute_base_indices_with_currency(currency)
    sym = "b_#{currency.name.downcase}".to_sym
    currency_ordinals = currency.ordinals
    ordinals.each { |day,values| values[sym] = values[:b] / currency_ordinals[day][:b] }
  end

#  def compute_yields_with_currency(currency)
#    sym = "y_#{currency.name.downcase}".to_sym
#    currency_ordinals = currency.ordinals
#    ordinals.each { |day,values| next if values[:y].nil? or currency_ordinals[day][:y].nil?; values[sym] = values[:y] / currency_ordinals[day][:y] }
#  end

  def compute_base_indices_with_currency_deflated_by(currency, index)
    sym = "b_#{currency.name.downcase}_#{index.name.downcase}".to_sym
    currency_ordinals = currency.ordinals
    index_ordinals = index.ordinals
    ordinals.each { |day,values| values[sym] = values[:b] / currency_ordinals[day][:b] / index_ordinals[day][:b] }
  end

  # Kovariancia számítása self és egy másik részvény, index vagy portfolió
  # között.
  def compute_covariance_with(ordinal, types)
    compute_call_for(types) do |t|
      next unless ordinal.aggregates[t]
      self.aggregates[t]["c_#{ordinal.name.downcase}".to_sym] = self.export_a(t).covariance(ordinal.export_a(t), self.aggregates[t][:m], ordinal.aggregates[t][:m])
    end
  end

  # Béta számlálása egy másik részvény, index vagy portfolió alapján.
  # b_mol_bux = COV_mol_bux / variance_bux
  def compute_beta_on(ordinal, types)
    compute_call_for(types) do |t|
      ordinal.compute_variance_for(t) unless ordinal.aggregates[t][:v]
      self.aggregates[t]["b_#{ordinal.name.downcase}".to_sym] = self.aggregates[t]["c_#{ordinal.name.downcase}".to_sym] / ordinal.aggregates[t][:v]
    end
  end

  def compute_systematic_risk_on(market, types)
    compute_call_for(types) do |t|
      self.aggregates[t]["rs_#{market.name.downcase}".to_sym] = self.aggregates[t]["b_#{market.name.downcase}".to_sym] * market.aggregates[t][:s]
    end
  end

  def compute_non_systematic_risk_on(market, types)
    compute_call_for(types) do |t|
      self.aggregates[t]["rn_#{market.name.downcase}".to_sym] = Math.sqrt(self.aggregates[t][:v] - self.aggregates[t]["rs_#{market.name.downcase}".to_sym]**2)
    end
  end

end

class Index < Ordinal

  # ez ugyanaz, mint a Stock#compute_base_indices_with_currency(currency)
  def compute_base_indices_with_currency(currency)
    sym = "b_#{currency.name.downcase}".to_sym
    currency_ordinals = currency.ordinals
    ordinals.each { |day,values| values[sym] = values[:b] / currency_ordinals[day][:b] }
  end

  #def compute_yields_with_currency(currency)
  #  sym = "y_#{currency.name.downcase}".to_sym
  #  currency_ordinals = currency.ordinals
  #  ordinals.each { |day,values| next if values[:y].nil? or currency_ordinals[day][:y].nil?; values[sym] = values[:y] / currency_ordinals[day][:y] }
  #end

end

class Currency < Ordinal
end

class Portfolio < Stock
  attr_reader :sources

  def initialize(stocks_with_weight, start_date, end_date, optimized=false)
    super(stocks_with_weight.map{|sw| sw[0].name.downcase}.sort.join('+') + (optimized ? "_#{optimized}" : ''), start_date, end_date)

    sum_weight = stocks_with_weight.inject(0.0) { |sw,stock_with_weight| sw + (stock_with_weight.first.ordinals.to_a.sort.first.last[:c]*stock_with_weight.last) }
    # sum_weight = stocks_with_weight.inject(0.0) { |sw,stock_with_weight| sw + stock_with_weight.last }
    net_weight = stocks_with_weight.inject(0.0) { |sw,stock_with_weight| sw + stock_with_weight.last }

    @sources = stocks_with_weight.inject({}) {|h,sw| h.merge(sw[0] => (sw[1] / sum_weight) ) }
    # @sources = stocks_with_weight.inject({}) {|h,sw| h.merge(sw[0] => sw[1]) }

    # Adatokat importál más portfoliókból (részvényekből) megadott súllyal
    stocks_with_weight.each do |stock,weight|
      stock.ordinals.each do |day,values|
        @ordinals[day]    ||= { :c => 0 }
        @ordinals[day][:c] += values[:c]*weight
      end
    end

    @ordinals.each { |day,values| values[:c] /= sum_weight / net_weight }
    # @ordinals.each { |day,values| values[:c] /= sum_weight }
  end

  def compute_covariance_matrix_for(types)
    source_names = sources.map{|s,w| [ s.name.downcase.to_sym, s ]}
    compute_call_for(types) do |t|
      return if self.aggregates[t][:cc]
      cc = self.aggregates[t][:cc] = {}
      source_names.each do |sn1,ordinal1|
        cc[sn1] = {}
        source_names.each do |sn2,ordinal2|
          cc[sn1][sn2] = if cc[sn2] and cc[sn2][sn1]
                           cc[sn2][sn1]
                         elsif sn1==sn2
                           ordinal1.aggregates[t][:v]
                         else
                           ordinal1.export_a(t).covariance(ordinal2.export_a(t), ordinal1.aggregates[t][:m], ordinal2.aggregates[t][:m])
                         end
        end
      end
    end
  end

  ## ## Ezekre nincs szükség
  ## def compute_variance_by_covariance_matrix_for(types)
  ##   source_names = sources.map{|s,w| [ s.name.downcase, s, w ]}
  ##   compute_call_for(types) do |t|
  ##     sum = 0.0
  ##     source_names.each do |sn1,ordinal1,weight1|
  ##       source_names.each do |sn2,ordinal2,weight2|
  ##         sum += weight1*weight2*self.aggregates[t][:cc][sn1][sn2]
  ##       end
  ##     end
  ##     self.aggregates[t][:v_cc] = sum
  ##     self.aggregates[t][:s_cc] = Math.sqrt(sum)
  ##   end
  ## end

  # Az űberszopó rész
  def minimize_non_systematic_risk_on(market, t)
    # Ez a sorrend!
    sources = self.sources.map{|s,w| [ s.name.downcase, s, w ]}

    # Alapbeállítások
    dimensions     = sources.size - 1
    initial_vector = GSL::Vector.alloc(dimensions)
    initial_vector.set_all(1.0 / (dimensions+1.0))
    #sources[0...-1].each_with_index { |s,i| initial_vector[i] = s[2] }

    initial_step   = GSL::Vector.alloc(dimensions)
    initial_step.set_all(0.1)

    iterations     = 100

    epsilon        = 1e-5 # ennyi alatt fogadjuk el az eredményt

    # Kovariancia mátrix
    cm = []
    sources.each_with_index do |v1,i1|
      sn1, ordinal1, weight1 = v1
      cm << []
      sources.each_with_index do |v2,i2|
        sn2, ordinal2, weight2 = v2
        cm[i1] << if i1 > i2
                    cm[i2][i1]
                  elsif i1 == i2
                    ordinal1.aggregates[t][:v]
                  else
                    ordinal1.export_a(t).covariance(ordinal2.export_a(t), ordinal1.aggregates[t][:m], ordinal2.aggregates[t][:m])
                  end
      end
    end

    my_function    = Proc.new { |v, cm|
                       # a megadott súlyok alapján kiszámítjuk a célfüggvényt
                       w   = v.to_a
                       w  << 1.0 - w.inject(0.0){|s,e| s+e}
                       sum = 0.0
                       cm.each_with_index { |c_row,i1| c_row.each_with_index { |e,i2| sum += e*w[i1]*w[i2] } }
                       sum
                     }

    gsl_function   = GSL::MultiMin::Function.alloc(my_function, dimensions)
    gsl_function.set_params(cm)

    minimizer      = GSL::MultiMin::FMinimizer.alloc('nmsimplex', dimensions)
    minimizer.set(gsl_function, initial_vector, initial_step)

    path = []
    begin
      iterations -= 1
      status = minimizer.iterate()
      status = minimizer.test_size(epsilon)
      #if status == GSL::SUCCESS
      #  puts("converged to minimum at")
      #end
      #x = minimizer.x
      #printf("%5d ", iterations);
      #for i in 0...dimensions do
      #  printf("%10.3e ", x[i])
      #end
      #printf("f() = %7.3f size = %.3f\n", minimizer.fval, minimizer.size);
      results = {}
      minimizer.x.to_a.each_with_index{|e,i| results[sources[i].first] = e }
      results[sources.last.first] = 1.0 - results.to_a.map{|_,e| e}.inject(0.0){|s,e| s+e}
      path << [ results, minimizer.fval, minimizer.size ]
    end while status == GSL::CONTINUE and iterations > 0
    path
  end
  protected :minimize_non_systematic_risk_on

  # systematic_risk(constant) + non_systematic_risk = variance
  def compute_minimum_non_systematic_risk_on(market, types)
    compute_call_for(types) do |t|
      path = minimize_non_systematic_risk_on(market, t)
      w_min = self.aggregates[t][:w_min] = path.last.first
      self.aggregates[t][:w_min_path] = path
      self.aggregates[t][:v_min] = path.last[1]
      self.aggregates[t][:s_min] = Math.sqrt(path.last[1])
      self.aggregates[t]["y_min_#{market.name.downcase}".to_sym] = w_min.map { |k,v| [ self.sources.to_a.inject({}) { |h,ss| h.merge(ss[0].name.to_s.upcase => ss[0]) }[k.to_s.upcase].aggregates[t]["b_#{market.name.downcase}".to_sym], v ] }.inject(0.0) { |s,vv| s + vv[0]*vv[1] }
    end
  end
end

