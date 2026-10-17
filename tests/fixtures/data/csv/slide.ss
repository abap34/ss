import std:themes/default as *
import std:data/csv as csv

page results
  head! "Monte Carlo estimates"
  let table = text!(csv::to_markdown(readlines("estimates.csv")))
  ~ table.width == 980
end
