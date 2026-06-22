<!-- Thanks for contributing to rzwasi (Rizin → WebAssembly)! -->

## Summary

<!-- What does this change do? Patches, build flags, exported functions, version bumps? -->

## Related issues

<!-- e.g. Closes #123, relates to IndAlok/rzweb#NN -->

## Type of change

- [ ] Build script / patch fix
- [ ] New exported `rzweb_*` session function
- [ ] Rizin version bump
- [ ] jsdec / optional component
- [ ] CI / tooling
- [ ] Documentation

## Verification

- [ ] `./build.sh` completes locally (emsdk 3.1.50)
- [ ] Resulting `rizin.js` / `rizin.wasm` loads and runs in RzWeb
- [ ] New exports are added to `RZWEB_EXPORTED_FUNCTIONS` in `build.sh`
- [ ] Shell scripts pass `shellcheck --severity=error`

## Notes

<!-- Anything reviewers should know: upstream Rizin caveats, emscripten quirks, etc. -->
