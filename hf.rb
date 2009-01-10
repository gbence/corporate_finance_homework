%w( rubygems haml digest/sha1 dm-core dm-serializer dm-timestamps dm-is-state_machine sinatra sinatras-hat scruffy ).each { |lib| require lib }
%w( lib/constants.rb lib/date.rb lib/portfolio.rb lib/array.rb lib/model.rb lib/dm-model.rb lib/scruffy_overrides.rb ).each { |lib| require lib } # ezek a sajátkezűleg írt libek

module Haml::Helpers
  def tablesorter_pager_for(dom_id, colspan=nil)
    return ""
    %{<tr id="#{dom_id.to_s}_pager">
  <td class="{ sorter: false } like_th"#{ colspan ? " colspan=\"#{colspan}\"" : ""}>
    <form action="#">
      <img src="/tablesorter/icons/first.png" class="first" alt="first"/>
      <img src="/tablesorter/icons/prev.png" class="prev" alt="prev"/>
      <input type="text" class="pagedisplay"/>
      <img src="/tablesorter/icons/next.png" class="next" alt="next"/>
      <img src="/tablesorter/icons/last.png" class="last" alt="last"/>
      <select class="pagesize">
        <option selected="selected" value="10">10</option><option value="20">20</option><option value="50">50</option><option value="100">100</option>
      </select>
    </form>
  </th>
</tr>}
  end
  def format_value_or_dash(format, value)
    value && (format % value) || '&ndash;'
  end
end

def fire_process!(url_hash)
  Net::HTTP.start(request.env['SERVER_NAME'], request.env['SERVER_PORT']) do |http|
    begin
      http.read_timeout = 0.5
      http.request_get("/solutions/#{url_hash}/process")
    rescue Timeout::Error
      # ez teljesen normális, 1mp alatt úgyse' lesz kész
    end
  end
end

configure :development do
  DataMapper.setup(:default, :adapter => 'sqlite3', :database => 'db/development.sqlite3')
  DataMapper.auto_migrate!
end

configure :production do
  DataMapper.setup(:default, :adapter => 'sqlite3', :database => 'db/production.sqlite3')
end

get '/' do
  redirect '/index.html', 301
end

get '/index.html' do
  haml :index
end

get '/hf.css' do
  content_type 'text/css', :charset => 'utf-8'
  sass :hf
end

get '/query.html' do
  begin
    haml :query, :locals => { :stocks => request_stocks_metadata_from_portfolio, :currencies => request_currencies_metadata_from_portfolio, :status => true }
  rescue PortfolioError
    haml :query, :locals => { :status => false }
  end
end

post '/solutions' do
  s = Solution.create(:parameters => {
    :start => params[:start],
    :end => params[:end],
    :stocks => [ [ params[:stock_1].to_i, params[:weight_1].to_f ], [ params[:stock_2].to_i, params[:weight_2].to_f ], [ params[:stock_3].to_i, params[:weight_3].to_f ] ],
    :currencies => [ 'huf', params[:currency_1] ],
    :name => params[:name],
    :email => params[:email]
  })
  fire_process!(s.url_hash)
  #sleep 0.2 # mesterséges sleep #2
  redirect "/solutions/#{s.url_hash}", 301
end

get '/solutions/:url_hash' do
  s = Solution.first(:url_hash => params[:url_hash])
  if s.nil?
    redirect '/query.html', 301
#  elsif s.state == 'generated'
#    redirect "/solutions/#{s.parameters[:name].downcase.gsub(/[^a-z0-9]{1,}/, '_')}.pdf", 301
  else
    s.solve! if s.state == 'new'
    haml :solution, :locals => { :solution => s }
  end
end

get '/solutions/:url_hash/regenerate' do
  s = Solution.first(:url_hash => params[:url_hash])
  redirect('/query.html', 301) if s.nil?
  s.solve!
  #fire_process!(s.url_hash)
  redirect "/solutions/#{s.url_hash}", 301
end

## for internal invokes only!
#get '/solutions/:url_hash/process' do
#  s = Solution.first(:url_hash => params[:url_hash])
#  begin
#    s.solve!
#    throw :halt, [ 200, 'ok' ]
#  rescue
#    p $!
#    throw :halt, [ 404, 'not' ]
#  end
#end

get '/solutions' do
  haml :solutions, :locals => { :solutions => Solution.all(:order => ['created_at']) }
end

# notes
# beta>1 felnagyítja a piac mozgását
