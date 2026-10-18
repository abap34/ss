import std:text as text_api
import std:assets as assets
import std:code as code_api
import std:document as document_api
import std:themes/default as base
import std:theme/types as { Theme }
import std:text/style as { TextBlockStyle }
import std:text/types as { TextParseMode }

const theme: Theme = base::default_theme()
const body_style: TextBlockStyle = theme.body with {
  text.size = 24
  text.parse = TextParseMode.block
}

fn body_page_number(page: Page, document: Document) -> String
  return str(page_index(page) - 1)
end

fn footer_number(page: Page, document: Document) -> String
  return body_page_number(page, document) ++ "/" ++ str(page_count(document) - 1)
end

const footer: document_api::PageNumber = document_api::PageNumber {
  format = footer_number
  style = theme.generated.pageno
}

type Section {
  title: String
}

fn/! section(title: String) -> Section = Section { title = title }

fn display(self: Placed<Section>) -> text_api::Text
  return text_api::Text { content = self.value.title style = theme.h1 }
end

type Contents {
  format: (Page, Document) -> String = body_page_number
}

fn display(self: Placed<Contents>) -> text_api::Text
  let sections = select<Section>(self.document)
  let format = self.value.format
  return text_api::Text {
    content = join(sections, "
", (section: Placed<Section>) |-> "- " ++ section.value.title ++ " ... " ++ format(section.page, section.document))
    style = body_style
  }
end

page cover
  let title = place!(text_api::Text {
    content = "A reproducible reporting pipeline"
    style = theme.h1 with { text.size = 48 }
  })
  let subtitle = place!(text_api::Text {
    content = "Typed inputs, reusable displays, and document queries"
    style = theme.body with { text.size = 28 }
  })
  ~ title.left == page.left + 64
  ~ title.top == page.top - 184
  ~ subtitle.left == title.left
  ~ subtitle.top == title.bottom - 32
end

page contents
  let title = place!(text_api::Text { content = "Contents" style = theme.h1 })
  let contents = place!(Contents {})
  let number = place!(footer)
  ~ title.left == page.left + 64
  ~ title.top == page.top - 56
  ~ contents.left == title.left
  ~ contents.top == title.bottom - 48
  ~ number.right == page.right - 64
  ~ number.bottom == page.bottom + 28
end

page architecture
  let title = section!("From source data to a slide")
  let explanation = place!(text_api::Text {
    content = <<
### Keep the inputs explicit

- Read and validate source records.
- Keep content and style in immutable values.
- Reuse the same definition across pages.

**Placement** gives each use its own identity and position.
>>
    style = body_style
  })
  let chart = place!(assets::Image {
    path = "../layout/practical/diagram.svg"
    style = theme.image with { asset.scale = 0.7 }
  })
  let number = place!(footer)
  ~ title.left == page.left + 64
  ~ title.top == page.top - 56
  ~ explanation.left == title.left
  ~ explanation.top == title.bottom - 48
  ~ explanation.width == 540
  ~ chart.left == page.left + 720
  ~ chart.top == explanation.top
  ~ number.right == page.right - 64
  ~ number.bottom == page.bottom + 28
end

page implementation
  let title = section!("Reuse one definition across pages")
  let program = place!(code_api::Code {
    source = <<
def compile_report(source):
    records = read_records(source)
    valid = validate(records)
    return build_slides(valid)
>>
    language = "python"
    style = theme.code with { text.size = 22 }
  })
  let architecture = first(select<Section>(docctx()))
  let reference = place!(text_api::Text {
    content = "See the architecture on page " ++ body_page_number(architecture.page, architecture.document) ++ "."
    style = body_style
  })
  let number = place!(footer)
  ~ title.left == page.left + 64
  ~ title.top == page.top - 56
  ~ program.left == title.left
  ~ program.top == title.bottom - 40
  ~ reference.left == program.left
  ~ reference.top == program.bottom - 40
  ~ number.right == page.right - 64
  ~ number.bottom == page.bottom + 28
end
