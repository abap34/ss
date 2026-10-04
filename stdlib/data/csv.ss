;; Usage: import std:data/csv as csv
;;        csv::show_table! "results.csv"
;; Use header=false for a file without a header record.
;; to_markdown accepts CSV text directly for composition with text.

import std:themes/default as theme
import std:themes/base as base

const newline: String = "
"

;; csv_map passes (cell, one-based record, one-based column, end_row) to a
;; String-returning callback, followed by any extra arguments. It validates
;; UTF-8, quoting, and equal record widths before invoking callbacks.
;; CSV is literal data. Escape Markdown syntax before constructing a table.
const backslash: String = <<
\
>>

fn escape_cell(value: String) -> String
  let backslashes = replace(value, backslash, backslash ++ backslash)
  let ampersands = replace(backslashes, "&", backslash ++ "&")
  let pipes = replace(ampersands, "|", backslash ++ "|")
  let less_than = replace(pipes, "<", backslash ++ "<")
  let greater_than = replace(less_than, ">", backslash ++ ">")
  let asterisks = replace(greater_than, "*", backslash ++ "*")
  let underscores = replace(asterisks, "_", backslash ++ "_")
  let backticks = replace(underscores, "`", backslash ++ "`")
  let open_brackets = replace(backticks, "[", backslash ++ "[")
  let close_brackets = replace(open_brackets, "]", backslash ++ "]")
  let dollars = replace(close_brackets, "$", backslash ++ "$")
  let tildes = replace(dollars, "~", backslash ++ "~")
  return replace(tildes, newline, " ")
end

fn cell_start(column: Number) -> String
  if column == 1
    return "|"
  end
  return ""
end

fn cell_end(end_row: Bool) -> String
  if end_row
    return newline
  end
  return ""
end

fn header_rule(value: String, row: Number, column: Number, end_row: Bool) -> String
  if row > 1
    return ""
  end
  return cell_start(column) ++ " --- |" ++ cell_end(end_row)
end

fn render_cell(value: String, row: Number, column: Number, end_row: Bool, separator: String, header: Bool) -> String
  let cell = cell_start(column) ++ " " ++ escape_cell(value) ++ " |" ++ cell_end(end_row)
  if header
    if row == 1
      if end_row
        return cell ++ separator
      end
    end
  end
  return cell
end

;; Quoted cell newlines become spaces in the displayed Markdown table.
;; Numeric-looking cells remain strings, preserving zeroes and decimal places.
fn to_markdown(data: String, header: Bool = true) -> String
  let separator = csv_map(data, header_rule)
  let body = csv_map(data, render_cell, separator, header)
  if header
    return body
  end
  return replace(separator, "---", "") ++ separator ++ body
end

;; show_table constructs an Object; show_table! also places it on the current page.
;; Paths use the same asset base directory and input tracking as readlines.
fn/! show_table(path: String, header: Bool = true, style: base::Theme = theme::current_theme()) -> Object
  return theme::text(to_markdown(readlines(path), header), style)
end
