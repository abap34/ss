import std:prelude as *
import std:text/style as { TextBlockStyle }
import std:code/style as { CodeBlockStyle }

const plain: TextBlockStyle = TextBlockStyle {} with { text.parse = TextParseMode.plain }
const short: Text = text("Short", plain)
const long: Text = text("A longer paragraph keeps the same assigned width while its words occupy more lines when the available column is narrow. The neighboring image retains its dimensions.", plain)
const picture: Image = image("diagram.svg")

page single
  let content = place!(short)
end

page text_image
  let content = place!(short || picture)
end

page longer_text_image
  let content = place!(long || picture)
end

page image_text
  let content = place!(picture || long)
end

page nested_column
  let content = place!((short // long) || picture)
end

page three_texts
  let content = place!(short || short || short)
end

page equal_three_texts
  let content = place!(short |=| short |=| short)
end

page padded_image
  let padded = picture with { style.chrome.pad_x = 12 }
  let content = place!(short || padded)
end

page explicit_text
  let content = place!(long)
  ~ content.width == 300
end

page smaller_image
  let content = place!(picture)
  ~ content.width == 150
end

page larger_image
  let content = place!(picture)
  ~ content.width == 500
end

page equal_images
  let content = place!(picture |=| picture)
  ~ content.width == 332
end

page code_unwrapped
  let content = code!("return alpha + beta + gamma + delta + epsilon + zeta + eta + theta", "python")
end

page code_wrapped
  let content = code!("return alpha + beta + gamma + delta + epsilon + zeta + eta + theta", "python", CodeBlockStyle {} with { layout.wrap = WrapMode.on chrome.pad_x = 12 })
  ~ content.width == 250
end

page left_anchor
  let content = place!(short)
  ~ content.left == page.left + 200
end

page right_anchor
  let content = place!(short)
  ~ content.right == page.left + 1000
end

page center_anchor
  let content = place!(short)
  ~ content.center_x == page.left + 600
end

page both_edges
  let content = place!(short)
  ~ content.left == page.left + 200
  ~ content.right == page.left + 600
end

page text_shape
  let content = place!(short || rectangle(160, 100))
end

page shape_text
  let content = place!(rectangle(160, 100) || short)
end

page different_padding
  let a = short with { style.chrome.pad_x = 12 }
  let b = short with { style.chrome.pad_x = 20 }
  let content = place!(a || b)
end

page nested_fixed_width
  let content = place!((short // long) || picture)
  ~ content.width == 600
end

page scaled_subpoint_image
  let content = place!(picture with { style.asset.scale = 0.001 })
end

page constrained_subpoint_image
  let content = place!(picture)
  ~ content.width == 0.3
end

page constrained_icon_height
  let content = icon!("fa-solid:star")
  ~ content.width == 100
  ~ content.height == 10
end

page padded_code
  let content = code!("return value", "python", CodeBlockStyle {} with { chrome.pad_x = 12 chrome.pad_y = 8 })
end
