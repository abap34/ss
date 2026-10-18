import std:assets/content as { Image, Pdf }
import std:assets/style as { AssetBlockStyle }
import std:assets/types as { PdfPageBox, AssetStyle }
import std:theme as theme
import std:internal/objects as objects
import std:internal/style as styles

fn/! image(path_value: String, factor: Number = 1, style: AssetBlockStyle = theme::current_theme().image) -> Object
  let obj = objects::img_obj(path_value)
  let image_style = style with {
    asset.scale = style.asset.scale * factor
  }
  styles::apply_asset_block_style(obj, image_style)
  require_asset_exists(obj)
  return obj
end

fn/! pdf(path_value: String, factor: Number = 1, page_number: Number = 1, page_box: PdfPageBox = PdfPageBox.crop, style: AssetBlockStyle = theme::current_theme().pdf) -> Object
  let obj = objects::pdf_obj(path_value)
  let pdf_style = style with {
    asset.scale = style.asset.scale * factor
    asset.pdf_page = page_number
    asset.pdf_box = page_box
  }
  styles::apply_asset_block_style(obj, pdf_style)
  require_asset_exists(obj)
  return obj
end

fn/! icon(source: String, width: Number = 72, height: Number = 72, color: Color = c"#374151") -> Object
  let obj = objects::icon_obj(source)
  obj.asset.tint = color
  ~ obj.width == width
  ~ obj.height == height
  return obj
end
