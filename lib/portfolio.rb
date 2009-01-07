# Ebben az állományban vannak azok a metódosuok, amik a szükséges adatokat
# leszedik a portfolio.hu-ról.
require 'uri'
require 'net/http'

class PortfolioError < StandardError; end

def request_data_from_portfolio(path, method=:get, parameters={})
  cache_file_path = SINATRA_ROOT + "/cache/"+("#{method.to_s}_#{path}_#{parameters.to_a.map{|_| _.map{|__| __.to_s}.join('_')}.sort.join('_')}".downcase.gsub(/[^a-z0-9]{1,}/, '_').gsub(/^_|_$/, ''))
  File.delete(cache_file_path) if File.exist?(cache_file_path) and (File.lstat(cache_file_path).mtime < Time.now - 86400)
  data = File.read(cache_file_path)
  yield(data) if block_given?
  data
rescue Errno::ENOENT
  data = nil
  Net::HTTP.start('www.portfolio.hu') do |http|
    p "request from www.portfolio.hu (#{path}, #{method.inspect})"
    response = case method
               when :get, /get/i
                 http.request_get(path)
               else
                 http.request_post(path, parameters.to_a.map{|_| _.map{|__| __.to_s}.join('=')}.join('&'))
               end
    raise PortfolioError, 'Cannot connect to portfolio.hu' unless response.code == '200'
    data = response.body
  end
  File.open(cache_file_path, 'w') { |f| f.write(data) } # caching
  yield(data) if block_given?
  data
end

def request_stocks_metadata_from_portfolio
  request_data_from_portfolio('/xmlhttp/gettickers.tdp?type=1').split("\n").map{|o| md=o.match(/<option value="([0-9]*):([-0-9]*):([-0-9]*)">([\/0-9a-zA-Z]*)/) && { :id => $1.to_i, :start => $2, :end => $3, :name => $4 } || nil}.compact
end

def request_stock_data_from_portfolio(id, start_date_string, end_date_string)
  stocks     = request_stocks_metadata_from_portfolio
  stock      = stocks.find { |s| s[:id] == id }
  ticker     = "#{id.to_s}:#{stock[:start]}:#{stock[:end]}" # ez kell több helyen is az inputban
  raw_data   = request_data_from_portfolio('/history/reszveny-adatok.tdp', :post, :tipus => "1", :rticker => ticker, :startdate => stock[:start], :enddate => stock[:end], :close => '1', :ticker => ticker, :text => 'szövegfájl')
  data       = raw_data.split("\n").map { |l| (l=~/^([12][90][1890][0-9])-([01][0-9])-([0123][0-9])\s*([0-9\.]*)$/) && { :date => Date.new($1.to_i, $2.to_i, $3.to_i), :close => $4.to_f } }.compact
  start_date = Date.parse(start_date_string)
  end_date   = Date.parse(end_date_string)
  [ stock[:name], stock[:start], stock[:end], data.select { |d| d[:date] >= start_date && d[:date] <= end_date } ]
end

def request_indices_metadata_from_portfolio
  request_data_from_portfolio('/xmlhttp/gettickers.tdp?type=0').split("\n").map{|o| md=o.match(/<option value="([0-9]*):([-0-9]*):([-0-9]*)">([\/0-9a-zA-Z]*)/) && { :id => $1.to_i, :start => $2, :end => $3, :name => $4 } || nil}.compact
end

def request_index_data_from_portfolio(id, start_date_string, end_date_string)
  indices    = request_indices_metadata_from_portfolio
  index      = indices.find { |s| s[:id] == id }
  ticker     = "#{id.to_s}:#{index[:start]}:#{index[:end]}" # ez kell több helyen is az inputban
  raw_data   = request_data_from_portfolio('/history/reszveny-adatok.tdp', :post, :tipus => "0", :rticker => ticker, :startdate => index[:start], :enddate => index[:end], :close => '1', :ticker => ticker, :text => 'szövegfájl')
  data       = raw_data.split("\n").map { |l| (l=~/^([12][90][1890][0-9])-([01][0-9])-([0123][0-9])\s*([0-9\.]*)$/) && { :date => Date.new($1.to_i, $2.to_i, $3.to_i), :close => $4.to_f } }.compact
  start_date = Date.parse(start_date_string)
  end_date   = Date.parse(end_date_string)
  [ index[:name], index[:start], index[:end], data.select { |d| d[:date] >= start_date && d[:date] <= end_date } ]
end

def request_currencies_metadata_from_portfolio # TODO
  [
    { :id => 'gbp', :start => '1999-01-04', :end => Date.today.to_s, :name => 'GBP' },
    { :id => 'aud', :start => '1999-01-04', :end => Date.today.to_s, :name => 'AUD' },
    { :id => 'czk', :start => '1999-01-04', :end => Date.today.to_s, :name => 'CZK' },
    { :id => 'dkk', :start => '1999-01-04', :end => Date.today.to_s, :name => 'DKK' },
    { :id => 'eur', :start => '1999-01-04', :end => Date.today.to_s, :name => 'EUR' },
    { :id => 'jpy', :start => '1999-01-04', :end => Date.today.to_s, :name => 'JPY' },
    { :id => 'cad', :start => '1999-01-04', :end => Date.today.to_s, :name => 'CAD' },
    { :id => 'pln', :start => '1999-01-04', :end => Date.today.to_s, :name => 'PLN' },
    { :id => 'nok', :start => '1999-01-04', :end => Date.today.to_s, :name => 'NOK' },
    { :id => 'chf', :start => '1999-01-04', :end => Date.today.to_s, :name => 'CHF' },
    { :id => 'sek', :start => '1999-01-04', :end => Date.today.to_s, :name => 'SEK' },
    { :id => 'skk', :start => '1999-01-04', :end => Date.today.to_s, :name => 'SKK' },
    { :id => 'usd', :start => '1999-01-04', :end => Date.today.to_s, :name => 'USD' }
  ]
end

def request_currency_data_from_portfolio(id_str, start_date_string, end_date_string)
  raw_data   = request_data_from_portfolio('/history/mnb_deviza-adatok.tdp', :post, :deviza => id_str, :startdate => '1999-01-01', :enddate => Date.today.to_s, :text => 'szövegfájl')
  data       = raw_data.split("\n").map { |l| (l=~/^([12][90][1890][0-9])-([01][0-9])-([0123][0-9])\s*([0-9\.]*)$/) && { :date => Date.new($1.to_i, $2.to_i, $3.to_i), :close => $4.to_f } }.compact
  start_date = Date.parse(start_date_string)
  end_date   = Date.parse(end_date_string)
  [ id_str, start_date, end_date, data.select { |d| d[:date] >= start_date && d[:date] <= end_date } ]
end

