The full EnviousWispr codebase is available on GitHub at [github.com/saurabhav88/EnviousWispr](https://github.com/saurabhav88/EnviousWispr). Every privacy claim is verifiable by reading the code.

## License

EnviousWispr is open source under the **GNU General Public License v3 (GPLv3)**, an OSI-approved license. Key points:

* **Free to use, study, modify, and redistribute**, including for commercial purposes, under the terms of the GPL.
* **Copyleft.** If you distribute a modified version, that version must also be licensed under the GPLv3 with its source available.
* **Trademarks reserved.** The EnviousWispr name and logo are trademarks of Envious Labs LLC and are not licensed under the GPL.

## Contributing

Community contributions are welcome. You can:

* Report issues on the GitHub Issues tracker.
* Submit pull requests for bug fixes or improvements.
* Inspect the code to verify privacy and security claims.

## Building from Source

EnviousWispr builds with the Swift compiler toolchain (CLT only, no Xcode required). It targets macOS 14+ on Apple Silicon.

```
swift build              # Debug build
swift build -c release   # Release build
```