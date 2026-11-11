import std:assets as assets

page Frames
  stages i { 7:-2:3 1 }
  let frame = assets::image!("frame-" ++ str(i) ++ ".svg")
  ~ frame.width == 180
end

page Appendix
  stages i { 2:-1:1 }
  let sheet = assets::pdf!("appendix.pdf", assets::AssetBlockStyle {} with {
    asset.pdf_page = i
  })
  ~ sheet.width == 240
end
