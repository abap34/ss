import assert from "node:assert/strict";

export async function checkForwardTypes({ source, texts, run }) {
  const functions = `fn keep<T>(peer: Ref<T>, value: T) -> T = value
fn id<T>(value: T) -> T = value
fn wrap<A, B>(unused: A, value: B) -> B = value
fn label(r: Ref<Placed<Text>>) -> String = (*r).value.content.source`;
  const deck = lines => [functions, "page main", ...lines, "end"].join("\n");
  for (const reverse of [false, true]) {
    for (const annotated of [[], ["a"], ["b"], ["a", "b"]]) {
      const declarations = (reverse ? ["b", "a"] : ["a", "b"]).map(name =>
        `  let ${name}${annotated.includes(name) ? ": Placed<Text>" : ""} = keep(&${name === "a" ? "b" : "a"}, text!("${name.toUpperCase()}"))`);
      const rendered = await texts(await source(deck([...declarations, '  text!("Both " ++ label(&a) ++ label(&b))'])));
      assert(rendered.includes("Both AB"));
    }
  }

  for (const rhs of ['id(text!("Target"))', 'id<Placed<Text>>(text!("Target"))', "make()", "ordinary"]) {
    const rendered = await texts(await source(deck([
      '  text!("Read " ++ label(&target))', '  let make = () |-> text!("Target")',
      '  let ordinary = make()', `  let target = ${rhs}`,
    ])));
    assert(rendered.includes("Read Target"));
  }

  // The result uses B, so A does not create a type edge. A is still inferred
  // and checked when validating the body of the page.
  const peer = await texts(await source(deck([
    '  let a = wrap(&b, text!("A"))', '  let b = wrap(&a, text!("B"))', '  text!(label(&a) ++ label(&b))',
  ])));
  assert(peer.includes("AB"));

  // The result type of a named query also depends on its statically known
  // name. The prepass must request that fact in the declaration's own scope.
  for (const declaration of [
    "let name = id(query_name())",
    "let name: String = id(query_name())",
    'let name: String = "self_placement"',
    'let prefix: String = "self_"\n  let name: String = prefix ++ "placement"',
  ]) {
    const named = await source(`${functions}
fn query_name() -> String
  let query: String = "self_placement"
  return query
end
page main
  let handle = &target
  let p = text!("Singleton")
  ${declaration}
  let target = first(select(p, name))
  let n = page_index((*handle).page)
end`);
    assert.deepEqual(await texts(named), ["Singleton"]);
  }

  const cross = await texts(await source(`${functions}
page early
  let peer = &late::target
  text!("Read " ++ label(peer))
end
page late
  let value = id(text!("Across"))
  let target = id(value)
end`));
  assert(cross.includes("Read Across"));

  const throughLocal = await texts(await source(`${functions}
type Box<T> { item: T }
page front
  text!("Local " ++ label(&target))
  let title = (*&back::origin).value.content.source
  let box = Box { item = text!(title) }
  let target = box.item
end
page back
  let origin = id(text!("Across"))
end`));
  assert(throughLocal.includes("Local Across"));

  const stages = await texts(await source(`${functions}
page staged
  stages s { first second }
  text!("Read " ++ label(&target))
  let target = id(text!("Stage"))
end`));
  assert.equal(stages.filter(s => s === "Read Stage").length, 2);

  // The concrete return is independent of the peer. Normal checking still
  // checks the argument which was not needed for result inference.
  const wrong = await source(`fn accept(r: Ref<Placed<Heading>>, v: Placed<Text>) -> Placed<Text> = v
page main
  let r = &target
  let target = accept(&target, text!("Wrong peer"))
end`);
  assert.doesNotMatch(run(["dump", "--quiet", wrong], "TypeMismatch"), /ReferenceNeedsType/);

  const cycle = await source(`page first
  let through = *&second::b
  let a = through
end
page second
  let b = *&first::a
end`);
  const error = run(["dump", "--quiet", cycle], "ReferenceNeedsType");
  for (const name of ["first::through", "first::a", "second::b"]) assert(error.includes(name));

  for (const annotate of [null, "a", "b"]) {
    const declarations = ["a", "b"].map(n => `  let ${n}${annotate === n ? ": Placed<Text>" : ""} = *&${n === "a" ? "b" : "a"}`);
    const diag = run(["dump", "--quiet", await source(deck(declarations))], annotate ? "ExecutionDependencyCycle" : "ReferenceNeedsType");
    if (!annotate) {
      assert.match(diag, /main::a.*main::b|main::b.*main::a/);
      assert.doesNotMatch(diag, /ExecutionDependencyCycle/);
    } else assert.doesNotMatch(diag, /ReferenceNeedsType/);
  }
  for (const [rhs, diagnostic] of [["id(unknown)", "UnknownIdentifier"], ['id<Number>(text!("bad"))', "TypeMismatch"]]) {
    const diag = run(["dump", "--quiet", await source(deck(["  let handle = &target", "  let alias = handle", `  let target = ${rhs}`, '  let later = text!("Later")']))], diagnostic);
    assert.doesNotMatch(diag, /ReferenceNeedsType/);
  }

  const depth = 256;
  const aliases = Array.from({ length: depth }, (_, n) => `  let p${n} = id(*&p${n + 1})`);
  assert((await texts(await source(deck(['  text!("Read " ++ label(&p0))', ...aliases, `  let p${depth} = text!("Tail")`])))).includes("Read Tail"));
}
