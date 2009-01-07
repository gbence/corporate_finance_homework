class Array
  def mean
    (self.inject(0.0){|s,e| s+e.to_f}) / self.size.to_f
  end

  def variance(mean=nil)
    mean = self.mean unless mean
    (self.inject(0.0){|s,e| s + (e.to_f-mean)**2.0}) / self.size.to_f
  end

  def standard_deviation(mean=nil)
    Math.sqrt(self.variance(mean))
  end

  def sample_variance(mean=nil)
    mean = self.mean unless mean
    (self.inject(0.0){|s,e| s + (e.to_f-mean)**2.0}) / (self.size.to_f-1.0)
  end

  def sample_standard_deviation(mean=nil)
    Math.sqrt(self.sample_variance(mean))
  end

  # cov_a_b = \sum((a_i - a_mean)*(b_i - b_mean)) / n
  def covariance(array2, mean1=nil, mean2=nil)
    array1 = self.compact
    array2 = array2.compact
    raise ArgumentError, 'Cannot compute covariance for two vectors with different sizes' unless array1.size == array2.size
    mean1 ||= array1.mean
    mean2 ||= array2.mean
    sum = 0.0
    array1.each_with_index { |e,i| sum += (e-mean1)*(array2[i]-mean2) }
    sum / array1.size.to_f
  end
end

