# Vendored dependencies

All required Solidity files are ordinary files under `lib/`. Builds and tests need no package download, Git submodule, npm install, or environment variables. The toolchain supplies Foundry and the pinned Solidity 0.8.26 compiler.

| Dependency | Pinned release | Included files | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | [v5.1.0](https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.1.0) | ERC20, Ownable/Ownable2Step, Pausable, ReentrancyGuard, ERC2981 and their transitive imports | `lib/openzeppelin-contracts/LICENSE` (MIT) |
| ERC721A | [v4.3.0](https://github.com/chiru-labs/ERC721A/releases/tag/v4.3.0) | ERC721A and IERC721A | `lib/erc721a/LICENSE.txt` (MIT) |
| forge-std | [v1.9.4](https://github.com/foundry-rs/forge-std/releases/tag/v1.9.4) | Upstream Solidity `src/` files for tests and the external verification harness | `lib/forge-std/LICENSE-MIT`, `LICENSE-APACHE` |

The selected upstream files are unmodified. `dependencies.lock.json` records each release URL, the downloaded archive's SHA-256 digest, and the digest of every retained file. Run `python3 scripts/check_dependencies.py` to verify the vendored files locally. Release package metadata is retained for provenance; its development scripts are not part of this project's build.
