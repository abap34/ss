import std:text/style as { TextBlockStyle, default_text_style }
import std:assets/style as { ImageStyle }
import std:graphics/types as { VectorStyle }

type ThemeOptions {
  font_family: String? = none
  code_font_family: String? = none
  text_color: Color? = none
  accent_color: Color? = none
  muted_color: Color? = none
}

type PageAppearance {
  background_fill: Color? = none
}

type Theme {
  page: PageAppearance = PageAppearance {}
  text: TextBlockStyle = default_text_style
  image: ImageStyle = ImageStyle {}
  path_shape: VectorStyle = VectorStyle {}
}
