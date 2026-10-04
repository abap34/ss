import std:themes/default as *
import std:data/csv as csv

page results
  head! "Monte Carlo estimates"
  let table = csv::show_table! "estimates.csv"
  ~ table.width == 980
end
