import assert from "node:assert/strict";

export async function checkForwardBindings({ source, texts, run }) {
  let checked = 0;
  const render = async code => {
    const result = await texts(await source(code));
    checked += 1;
    return result;
  };
  const page = body => `page main\n${body}\nend`;

  assert.deepEqual((await render(page(`
    let alias = title
    let handle = &title
    text!(alias.value.content.source ++ " / " ++ (*handle).value.content.source)
    let title = text!("Title")
  `))).sort(), ["Title", "Title / Title"]);

  // One lambda syntax produces distinct nested captures. Reusing a capture
  // must preserve both its literal prefix and its cross-page reference.
  const captured = await render(`
    type Caption { read: () -> String }
    type Captions { left: Caption right: Caption }
    fn display(self: Placed<Caption>) -> Text = text(self.value.read())
    fn decorate(prefix: String, read: () -> String) -> () -> String
      return () |-> prefix ++ read()
    end
    fn caption(prefix: String, target: Ref<Placed<Text>>) -> Caption
      return Caption { read = decorate(prefix, () |-> (*target).value.content.source) }
    end
    page main
      place!(captions.left)
      place!(captions.right)
      place!(captions.left)
      let captions = Captions {
        left = caption("Left ", &first::title)
        right = caption("Right ", &second::title)
      }
    end
    page first
      let title = text!("A")
    end
    page second
      let title = text!("B")
    end
  `);
  assert.deepEqual(captured.sort(), ["A", "B", "Left A", "Left A", "Right B"]);

  for (const [selector, declarations] of [
    ["pick(flag, &good, &other)", "let flag = true"],
    ["optional ?? &other", "let optional: Ref<Placed<Text>>? = &good"],
    ["fold(items, &good, (acc: Ref<Placed<Text>>, item: Placed<Heading>) |-> &other)",
      "let items = select<Heading>(pagectx())"],
    ["fold(items, &good, (acc: Ref<Placed<Text>>, item: Placed<Text>) |-> &other)",
      "let items = filter(selection(good), (item: Placed<Text>) |-> flag)\nlet flag = false"],
  ]) {
    const value = await render(`
      fn pick(flag: Bool, a: Ref<Placed<Text>>, b: Ref<Placed<Text>>) -> Ref<Placed<Text>>
        if flag
          return a
        end
        return b
      end
      ${page(`let result = text!((*chosen).value.content.source)
        let chosen = ${selector}
        let other = text!(result.value.content.source ++ " unreachable")
        ${declarations}
        let good = text!("Chosen")`)}
    `);
    assert.deepEqual(value.sort(), ["Chosen", "Chosen", "Chosen unreachable"]);
  }

  run(["dump", "--quiet", await source(page("let r = &n\nlet n = 1"))], "InvalidReferenceTarget");
  checked += 1;
  console.log(`Forward bindings with placement references: ${checked} documents passed`);
}
