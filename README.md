# fzy.zig

Rewrite of John Hawthorn's excellent [fzy][] in Zig.

See [Usage](#usage) for notable differences from the original.

[fzy]: https://github.com/jhawthorn/fzy

## Project Status

This repo is **experimental** and its primary purpose is for experimentation
and/or fun. Please abandon any expectations of this being a serious project.

## Building

Zig 0.11.0 is required. To clone and build, run:

```console
$ git clone https://git.sr.ht/~gpanders/fzy.zig
$ cd fzy.zig
$ zig build
```

This will build an `fzy` binary in `zig-out/bin/`. To install to a different
prefix, use the `-p` flag:

```console
$ zig build -p ~/.local
```

By default, `fzy.zig` is built in `Debug` mode. This is very slow. If you
intend to actually use `fzy`, you should compile in either `ReleaseSafe` or
`ReleaseFast` mode:

```console
$ zig build -Doptimize=ReleaseSafe
```

## Usage

Usage is the same as the original [fzy][] except for the following:

- Input is read concurrently with key events from the user. This means you can
  start typing your query right away rather than waiting for fzy to read the
  entire candidate list. This is especially noticeable when the input stream is
  slow.
- Multi-select support: press `Ctrl-T` to select multiple items.
- A `-f`/`--file` flag allows you to read input from a file:

      fzy -f input.txt

  This can of course also be done by just piping the file in over stdin:

      fzy < input.txt

- A `-n`/`--no-sort` flag that prevents `fzy` from sorting matches.

## Contributing

Questions, bugs, and patches can be sent to the [mailing list][].

[mailing list]: https://lists.sr.ht/~gpanders/public-inbox

## License

[MIT][]

[MIT]: ./LICENSE
