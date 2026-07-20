import { element } from "./dom.js";

const strokeStyles = [
  { value: "solid", label: "Solid" },
  { value: "dashed", label: "Dashed" },
  { value: "dotted", label: "Dotted" },
  { value: "dash_dot", label: "Dash-dot" },
];

export function strokeStylePicker(value, options) {
  const picker = element("details", "stroke-style-picker");
  const summary = element("summary");
  summary.setAttribute("aria-label", options.ariaLabel);
  summary.title = `${options.ariaLabel}: ${strokeStyleLabel(value)}`;
  summary.append(strokeLine(value));
  const chevron = element("span", "stroke-style-chevron");
  chevron.textContent = "⌄";
  summary.append(chevron);

  const panel = element("div", "stroke-style-menu");
  panel.setAttribute("role", "group");
  panel.setAttribute("aria-label", options.ariaLabel);
  for (const style of strokeStyles) {
    const button = element(
      "button",
      `stroke-style-option${style.value === value ? " is-active" : ""}`,
    );
    button.type = "button";
    button.disabled = Boolean(options.disabled);
    button.setAttribute("aria-label", style.label);
    button.append(strokeLine(style.value));
    const label = element("span");
    label.textContent = style.label;
    button.append(label);
    button.addEventListener("click", () => {
      picker.open = false;
      options.change(style.value);
    });
    panel.append(button);
  }
  picker.append(summary, panel);
  if (options.disabled) {
    picker.classList.add("is-disabled");
    summary.setAttribute("aria-disabled", "true");
    summary.addEventListener("click", (event) => event.preventDefault());
  }
  return picker;
}

export function strokeStyleSelect(value, options) {
  const control = element("label", "shape-stroke-style-select");
  const caption = element("span");
  caption.textContent = options.label;
  const select = element("select");
  select.setAttribute("aria-label", options.ariaLabel);
  for (const style of strokeStyles) {
    const option = element("option");
    option.value = style.value;
    option.textContent = style.label;
    option.selected = style.value === value;
    select.append(option);
  }
  select.disabled = Boolean(options.disabled);
  select.addEventListener("change", () => options.change(select.value));
  control.append(caption, select);
  return control;
}

function strokeLine(style) {
  const sample = element("span", `stroke-line stroke-line--${style}`);
  sample.setAttribute("aria-hidden", "true");
  return sample;
}

function strokeStyleLabel(value) {
  return strokeStyles.find((style) => style.value === value)?.label || "Solid";
}
