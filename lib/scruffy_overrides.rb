module Scruffy::Layers
  class LineWithoutDots < Base

    # Renders line graph.
    def draw(svg, coords, options={})
      svg.g(:class => 'shadow', :transform => "translate(#{relative(0.5)}, #{relative(0.5)})") {
        svg.polyline( :points => stringify_coords(coords).join(' '), :fill => 'transparent', 
                     :stroke => 'black', 'stroke-width' => relative(1), 
                     :style => 'fill-opacity: 0; stroke-opacity: 0.35' )

      }

      svg.polyline( :points => stringify_coords(coords).join(' '), :fill => 'none', 
                   :stroke => color.to_s, 'stroke-width' => relative(1) )
    end
  end
end

module Scruffy::Components
  class DataMarkers < Base
    def draw(svg, bounds, options={})
      unless options[:point_markers].nil?
        point_distance = bounds[:width] / (options[:point_markers].size - 1).to_f

        (0...options[:point_markers].size).map do |idx| 
          x_coord = point_distance * idx
          options[:point_markers][idx].split("\n").each_with_index do |text,index|
            svg.text(text,
                     :x => x_coord,
                     :y => bounds[:height]*0.75*(index+1), 
                     'font-size' => relative(50),
                     'font-family' => options[:theme].font_family,
                     :fill => (options[:theme].marker || 'white').to_s, 
                     'text-anchor' => 'middle') unless options[:point_markers][idx].nil?
          end
        end
      end
    end   # draw
  end   # class
end

module Scruffy::Components
  class Label < Base
    def draw(svg, bounds, options={})
      svg.text(@options[:text],
               :class => 'text',
               :x => (bounds[:width] / 2),
               :y => bounds[:height], 
               'font-size' => relative(80),
               'font-family' => options[:theme].font_family,
               :fill => options[:theme].marker,
               :stroke => 'none', 'stroke-width' => '0',
               'text-anchor' => (@options[:text_anchor] || 'middle'))
    end
  end
end

module Scruffy::Components
  class Legend < Base
    def draw(svg, bounds, options={})
      vertical = options[:vertical_legend]
      legend_info = relevant_legend_info(options[:layers])
      @line_height, x, y, size = 0
      if vertical
        set_line_height = 0.08 * bounds[:height]
        @line_height = bounds[:height] / legend_info.length
        @line_height = set_line_height if @line_height >
        set_line_height
      else
        set_line_height = 0.90 * bounds[:height]
        @line_height = set_line_height
      end

      text_height = @line_height * FONT_SIZE / 100
      # #TODO how does this related to @points?
      active_width, points = layout(legend_info, vertical)

      offset = (bounds[:width] - active_width) / 2    # Nudge over a bit for true centering

      # Render Legend
      points.each_with_index do |point, idx|
        if vertical
          x = 0
          y = point
          size = @line_height * 0.5
        else
          x = offset + point
          y = 0
          size = relative(50)
        end

        # "#{x} #{y} #{@line_height} #{size}"

        svg.rect(:x => x, 
                 :y => y, 
                 :width => size, 
                 :height => size,
                 :fill => legend_info[idx][:color])

        svg.text(legend_info[idx][:title], 
                 :x => x + @line_height, 
                 :y => y + text_height * 0.75,
                 'font-size' => text_height*0.7, 
                 'font-family' => options[:theme].font_family,
                 :style => "color: #{options[:theme].marker || 'white'}",
        :fill => (options[:theme].marker || 'white'))
      end
    end   # draw

    def layout(legend_info_array, vertical = false)
      if vertical
        longest = 0
        legend_info_array.each {|elem|
          cur_length = relative(50) * elem[:title].length
          longest = longest < cur_length ? cur_length : longest
        }
        y_positions = []
        (0..legend_info_array.length - 1).each {|y|
          y_positions << y * @line_height
        }
        [longest, y_positions]
      else
        legend_info_array.inject([0, []]) do |enum, elem|
          enum[0] += (relative(20) * 2) if enum.first != 0      # Add spacer between elements
          enum[1] << enum.first                                 # Add location to points
          enum[0] += relative(45)                               # Add room for color box
          enum[0] += (relative(45) * elem[:title].length)       # Add room for text

          [enum.first, enum.last]
        end        
      end
    end

  end
end

module Scruffy::Components
  class Title < Base
    def draw(svg, bounds, options={})
      if options[:title]
        svg.text(options[:title],
                 :class => 'title',
                 :x => (bounds[:width] / 2),
                 :y => bounds[:height], 
                 'font-size' => relative(70),
                 'font-family' => options[:theme].font_family,
                 :fill => options[:theme].marker,
                 :stroke => 'none', 'stroke-width' => '0',
                 'text-anchor' => (@options[:text_anchor] || 'middle'))
      end
    end
  end
end

module Scruffy::Components
  class ValueMarkers < Base
    attr_accessor :markers

    def draw(svg, bounds, options={})
      markers = (options[:markers] || self.markers) || 5
      all_values = []

      (0...markers).each do |idx|
        marker = ((1 / (markers - 1).to_f) * idx) * bounds[:height]
        all_values << (options[:max_value] - options[:min_value]) * ((1 / (markers - 1).to_f) * idx) + options[:min_value]
      end

      (0...markers).each do |idx|
        marker = ((1 / (markers - 1).to_f) * idx) * bounds[:height]
        marker_value = (options[:max_value] - options[:min_value]) * ((1 / (markers - 1).to_f) * idx) + options[:min_value]
        marker_value = options[:value_formatter].route_format(marker_value, idx, options.merge({:all_values => all_values})) if options[:value_formatter]

        svg.text( marker_value.to_s, 
                 :x => bounds[:width], 
                 :y => (bounds[:height] - marker), 
                 'font-size' => relative(6),
                 'font-family' => options[:theme].font_family,
                 :fill => ((options.delete(:marker_color_override) || options[:theme].marker) || 'white').to_s,
                 'text-anchor' => 'end')
      end

    end
  end
end

module Scruffy::Layers
  class Histogram < Base

    def draw(svg, coords, options = {})
      svg.g(:class => 'shadow', :transform => "translate(#{relative(0.5)}, #{relative(0.5)})") do
        coords.each do |coord|
          if coord[1].abs < 0.00001
            svg.rect(:x => coord[0], :y => @zero_point-relative(0.05), :width => @bar_width, :height => relative(0.1), :fill => 'black', :stroke => 'none', :style => 'opacity: 0.35')
          else
            svg.rect(:x => coord[0], :y => @zero_point, :width => @bar_width, :height => coord[1], :fill => 'black', :stroke => 'none', :style => 'opacity: 0.35')
          end
        end
      end

      coords.each do |coord|
        if coord[1].abs < 0.00001
          svg.rect(:x => coord[0], :y => @zero_point-relative(0.05), :width => @bar_width, :height => relative(0.1), :fill => 'white', :stroke => 'none' )
        else
          svg.rect(:x => coord[0], :y => @zero_point, :width => @bar_width, :height => coord[1], :fill => coord[1] > 0 ? '#f44' : '#4f4', :stroke => 'none' )
        end
      end
    end

    protected
    def generate_coordinates(options = {})
      gap         = 0.1
      width       = self.width.to_f * points.size / (points.size - gap).to_f
      @bar_width  = (width / points.size) * (1.0-gap)
      @zero_point = max_value*height / (max_value - min_value)
      bar_with_gap_width = (width - (width / points.size)) / (points.size - 1)

      i=-1; points.map { |p| p||=0.0; i+=1; [bar_with_gap_width * i, -(p*height) / (max_value - min_value)] }
    end

  end
end

module Scruffy
  class Graph
    # Returns the lowest value in any of this container's layers.
    #
    # If padding is set to :padded, a 15% padding is added below the lowest value.
    # If the lowest value is greater than zero, then the padding will not cross the zero line, preventing
    # negative values from being introduced into the graph purely due to padding.
    def bottom_value(padding=nil) # :nodoc:
      botval = layers.inject(top_value) { |min, layer| (min = ((min > layer.bottom_value) ? layer.bottom_value : min)) unless layer.bottom_value.nil?; min }
      above_zero = (botval > 0)
      botval = ((padding == :padded) ? botval - ((top_value - botval) * 0.15) : botval)

      # Don't introduce negative values solely due to padding.
      # A user-provided value must be negative before padding will extend into negative values.
      (above_zero && botval < 0) ? 0 : botval
    end
  end
end
