# fzy.zig

Rewrite of John Hawthorn's excellent [fzy][] in Zig.

This was mostly done as a learning exercise/out of curiosity. I don't recommend
using it unless you enjoy testing beta software.

[fzy]: https://github.com/jhawthorn/fzy

## Building

Obviously building fzy.zig requires a Zig toolchain. Currently Zig master is
required.

```console
$ git clone --recursive https://github.com/gpanders/fzy.zig
$ zig build
```

By default, `fzy.zig` is built in `ReleaseSafe` mode. This will crash the
program with a (somewhat) useful stack trace if a runtime error occurs. If
you're feeling brave, you can squeeze out extra performance at the expense of
runtime safety by building in `ReleaseFast` mode:

```console
$ zig build -Drelease-fast=true
```

## Usage

Usage is the same as the original [fzy][].

## License

[MIT][]

[MIT]: ./LICENSE
