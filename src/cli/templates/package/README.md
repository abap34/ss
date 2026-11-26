# {s}

A reusable ss package.

## Try the example

```sh
ss render --project . --output example.pdf
```

## Use in another project

```sh
ss add --git REPOSITORY_URL
```

```ss
import pkg:{s} as library

page example
  library::label!("Hello from a package")
end
```
