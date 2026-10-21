;; Common authoring functions. Implementation callbacks stay in their modules.
import std:graphics/types
import std:math/types
import std:assets/types
import std:layout/types
import std:code/types
import std:text/types
import std:graphics/paint/types
import std:theme/types
import std:layout as {
  place!,
  hflow,
  hflow_doc,
  vflow,
  vflow_doc,
}
import std:text as {
  Text,
  TextSemantics,
  SemanticRole,
  default_text_style,
  NEWLINE,
  text,
  text!,
}
import std:code as {
  Code,
  code,
  code!,
  code_file,
  code_file!,
}
import std:math as {
  Latex,
  Math,
  math,
  math!,
  latex,
  latex!,
}
import std:assets as {
  Image,
  Pdf,
  Icon,
  image,
  image!,
  pdf,
  pdf!,
  icon,
  icon!,
}
import std:components/toc as {
  toc,
  toc!,
  Toc,
}
import std:document as {
  Heading,
  PageNumber,
  heading,
  heading!,
  number_of,
  pageno,
  pageno!,
}
import std:themes/default as {
  default_theme,
}
import std:query as {
  previous_page,
  selection,
  filter,
  children,
  descendants,
  doc_pages,
  pages,
}
import std:graphics as {
  PathShape,
  path_shape,
  path_shape!,
  rectangle,
  rectangle!,
  circle,
  circle!,
  arrow_shape,
  arrow_shape!,
  speech_bubble,
  speech_bubble!,
  line,
  line!,
  elbow_line,
  elbow_line!,
  marker_arrow_open,
}
import std:graphics/path as {
  move_to,
  line_to,
  quadratic_to,
  cubic_to,
  arc_to,
  close_path,
}
import std:graphics/paint as {
  vector_stroke,
  no_stroke,
  solid_stroke,
  dashed_stroke,
  dotted_stroke,
  dash_dot_stroke,
  vector_style,
  no_fill,
  solid_fill,
  linear_fill,
  radial_fill,
  pattern_fill,
  with_pattern,
  gradient_right,
  gradient_left,
  gradient_down,
  gradient_up,
  gradient_down_right,
  gradient_up_right,
  gradient_down_left,
  gradient_up_left,
  linear_gradient_fill,
  radial_gradient_fill,
  hatch_up,
  hatch_down,
  crosshatch,
  horizontal_hatch,
  vertical_hatch,
  grid_pattern,
  dot_pattern,
  checker_pattern,
  wave_pattern,
  hatch_fill,
  crosshatch_fill,
  grid_fill,
  dots_fill,
  checker_fill,
  brick_fill,
  waves_fill,
  stipple_sparse_fill,
  stipple_fill,
  stipple_dense_fill,
}
