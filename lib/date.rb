class Date
  alias_method :month_original, :month
  def month(*args)
    unless args.empty?
      if args.first == :hu_HU
        %w{ január február március április május június július augusztus szeptember október november december }[month_original-1]
      end
    else
      month_original
    end
  end
end

